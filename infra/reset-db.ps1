# Reseta o MySQL ao estado-semente para que cada repetição comece idêntica (§3.7).
#
# LOCAL (default): TRUNCATE + recarga dos data.sql no contêiner docker.
# REMOTO (-SshHost): na AWS, recria o database e reaplica /schema.sql e /data.sql,
# que o user-data deixou dentro do contêiner, via SSH na EC2 do MySQL.

param(
  [Parameter(Mandatory)][ValidateSet('mono', 'micro', 'serverless')][string]$Target,
  [string]$SshHost = '',              # IP público da EC2 do MySQL (terraform output mysql_public_ip)
  [string]$SshKey = '',               # caminho da chave privada (.pem) do key pair
  [string]$SshUser = 'ec2-user',
  [string]$DbName = 'petclinic',
  [int]$VisitsPerPet = 200            # volume base da ficha agregada (§3.5)
)
$ErrorActionPreference = 'Stop'
# $IsWindows não existe no PS 5.1, que só roda no Windows.
$OnWindows = ($null -eq $IsWindows) -or $IsWindows
# Fora do Windows os escopos Machine/User devolvem null e zerariam o PATH.
if ($OnWindows) {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

# Logo após o cenário de pico centenas de ambientes de execução Lambda ainda seguram
# conexões do próprio pool, e o banco recusa novas com o erro 1040. A espera dá tempo
# de o provedor reciclá-los; sem ela, uma exaustão passageira derruba a bateria inteira
# e as repetições restantes do braço se perdem.
function Invoke-RemoteMysql {
  param([string[]]$SshArgs, [string]$Remote, [string]$Stdin = '', [string]$Step = '',
    [int]$Retries = 6)
  for ($i = 1; $i -le $Retries; $i++) {
    if ($Stdin) { $Stdin | & ssh @SshArgs $Remote } else { & ssh @SshArgs $Remote }
    if ($LASTEXITCODE -eq 0) { return }
    if ($i -lt $Retries) {
      $wait = 15 * $i
      Write-Warning "reset-db: '$Step' falhou (exit $LASTEXITCODE); nova tentativa em $wait s ($i/$Retries)"
      Start-Sleep -Seconds $wait
    }
  }
  throw "reset-db remoto: '$Step' falhou apos $Retries tentativas (exit $LASTEXITCODE)"
}

# --- Modo REMOTO (AWS): recria o database a partir do seed persistido no contêiner ---
if ($SshHost) {
  if (-not $SshKey) { throw "reset-db remoto: informe -SshKey (chave .pem do key pair)" }
  # ssh recusa chave privada legível por outros, e um .pem copiado costuma vir 644.
  if (-not $OnWindows) { & chmod 600 $SshKey }
  $sshBase = @('-i', $SshKey, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', "$SshUser@$SshHost")
  # 1) DROP + CREATE via stdin (evita aspas aninhadas Windows->ssh->sh)
  Invoke-RemoteMysql -SshArgs $sshBase -Step 'DROP/CREATE' `
    -Stdin "DROP DATABASE IF EXISTS $DbName; CREATE DATABASE $DbName;" `
    -Remote "docker exec -i mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot'"
  # 2) schema + 3) data — arquivos já dentro do contêiner (mysql-userdata.sh)
  foreach ($f in '/schema.sql', '/data.sql') {
    Invoke-RemoteMysql -SshArgs $sshBase -Step "aplicar $f" `
      -Remote "docker exec mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot $DbName < $f'"
  }
  # 4) volume base de visitas. A semente oficial traz 4 visitas em 13 animais, então
  # nove dos dez tutores teriam ficha sem visita alguma e a operação de agregação
  # nasceria trivial, só ganhando conteúdo com as escritas da própria medição.
  # Data fixa, e não CURDATE(), para o conjunto ser idêntico entre execuções.
  $seedVisits = "INSERT INTO $DbName.visits (pet_id, visit_date, description) " +
  "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < $VisitsPerPet) " +
  "SELECT p.id, DATE_SUB('2024-01-01', INTERVAL n.i DAY), CONCAT('baseline-', n.i) " +
  "FROM $DbName.pets p, n;"
  Invoke-RemoteMysql -SshArgs $sshBase -Step 'carga base de visitas' -Stdin $seedVisits `
    -Remote "docker exec -i mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot'"
  $n = (& ssh @sshBase "docker exec mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot -N -e \""SELECT COUNT(*) FROM $DbName.visits\""'") -join ''
  "reset-db: '$Target' resetado (remoto $SshHost — '$DbName' do seed + $($n.Trim()) visitas)."
  return
}

$root = Split-Path $PSScriptRoot -Parent
$mono = Join-Path $root 'apps/monolith/src/main/resources/db/mysql/data.sql'
$micro = Join-Path $root 'apps/microservices'

# Serverless reusa o schema e o seed do monolito.
$localTarget = if ($Target -eq 'serverless') { 'mono' } else { $Target }

$cfg = @{
  mono  = @{ container = 'petclinic-mysql'; user = 'petclinic'
             seeds = @($mono) }
  micro = @{ container = 'petclinic-micro-mysql'; user = 'root'
             seeds = @(
               (Join-Path $micro 'spring-petclinic-customers-service/src/main/resources/db/mysql/data.sql'),
               (Join-Path $micro 'spring-petclinic-vets-service/src/main/resources/db/mysql/data.sql'),
               (Join-Path $micro 'spring-petclinic-visits-service/src/main/resources/db/mysql/data.sql')
             ) }
}[$localTarget]

$c = $cfg.container
$u = $cfg.user
# MYSQL_PWD evita o aviso "password on command line" (poluiria o stderr)
$pwdArg = @('-e', 'MYSQL_PWD=petclinic')

# 1) lista as tabelas base do schema petclinic
$tables = docker exec @pwdArg $c mysql "-u$u" -N -e `
  "SELECT table_name FROM information_schema.tables WHERE table_schema='petclinic' AND table_type='BASE TABLE'"
if (-not $tables) { throw "reset-db: nenhuma tabela em '$c' (o stack '$Target' está de pé?)" }

# 2) TRUNCATE de todas (FK desligada durante a operação)
$trunc = "SET FOREIGN_KEY_CHECKS=0; " +
         (($tables | ForEach-Object { "TRUNCATE TABLE ``$_``;" }) -join ' ') +
         " SET FOREIGN_KEY_CHECKS=1;"
docker exec @pwdArg $c mysql "-u$u" petclinic -e $trunc | Out-Null

# 3) recarrega os data.sql (baseline)
foreach ($f in $cfg.seeds) {
  if (-not (Test-Path $f)) { throw "reset-db: seed não encontrado: $f" }
  Get-Content $f -Raw | docker exec -i @pwdArg $c mysql "-u$u" petclinic
}

# 4) volume base de visitas, pelo mesmo critério do modo remoto
$seedVisits = "INSERT INTO visits (pet_id, visit_date, description) " +
"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < $VisitsPerPet) " +
"SELECT p.id, DATE_SUB('2024-01-01', INTERVAL n.i DAY), CONCAT('baseline-', n.i) FROM pets p, n;"
docker exec @pwdArg $c mysql "-u$u" petclinic -e $seedVisits | Out-Null
$n = docker exec @pwdArg $c mysql "-u$u" petclinic -N -e "SELECT COUNT(*) FROM visits"

"reset-db: '$Target' resetado ($($tables.Count) tabelas, $($cfg.seeds.Count) seed(s), $n visitas)."
