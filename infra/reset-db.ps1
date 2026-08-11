# Reseta o MySQL ao estado-semente para que cada repetição comece idêntica (§3.7).
#
# LOCAL (default): TRUNCATE + recarga dos data.sql no contêiner docker.
# REMOTO (-SshHost): na AWS, recria o database e reaplica /schema.sql e /data.sql,
# que o user-data deixou dentro do contêiner, via SSH na EC2 do MySQL.

param(
  [Parameter(Mandatory)][ValidateSet('mono', 'micro')][string]$Target,
  [string]$SshHost = '',              # IP público da EC2 do MySQL (terraform output mysql_public_ip)
  [string]$SshKey = '',               # caminho da chave privada (.pem) do key pair
  [string]$SshUser = 'ec2-user',
  [string]$DbName = 'petclinic'
)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

# --- Modo REMOTO (AWS): recria o database a partir do seed persistido no contêiner ---
if ($SshHost) {
  if (-not $SshKey) { throw "reset-db remoto: informe -SshKey (chave .pem do key pair)" }
  $sshBase = @('-i', $SshKey, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=15', "$SshUser@$SshHost")
  # 1) DROP + CREATE via stdin (evita aspas aninhadas Windows->ssh->sh)
  "DROP DATABASE IF EXISTS $DbName; CREATE DATABASE $DbName;" |
    & ssh @sshBase "docker exec -i mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot'"
  if ($LASTEXITCODE -ne 0) { throw "reset-db remoto: DROP/CREATE falhou (exit $LASTEXITCODE)" }
  # 2) schema + 3) data — arquivos já dentro do contêiner (mysql-userdata.sh)
  foreach ($f in '/schema.sql', '/data.sql') {
    & ssh @sshBase "docker exec mysql sh -c 'MYSQL_PWD=`$MYSQL_ROOT_PASSWORD mysql -uroot $DbName < $f'"
    if ($LASTEXITCODE -ne 0) { throw "reset-db remoto: aplicar $f falhou (exit $LASTEXITCODE)" }
  }
  "reset-db: '$Target' resetado (remoto $SshHost — database '$DbName' recriado do seed)."
  return
}

$root = Split-Path $PSScriptRoot -Parent
$mono = Join-Path $root 'apps\monolith\src\main\resources\db\mysql\data.sql'
$micro = Join-Path $root 'apps\microservices'

$cfg = @{
  mono  = @{ container = 'petclinic-mysql'; user = 'petclinic'
             seeds = @($mono) }
  micro = @{ container = 'petclinic-micro-mysql'; user = 'root'
             seeds = @(
               (Join-Path $micro 'spring-petclinic-customers-service\src\main\resources\db\mysql\data.sql'),
               (Join-Path $micro 'spring-petclinic-vets-service\src\main\resources\db\mysql\data.sql'),
               (Join-Path $micro 'spring-petclinic-visits-service\src\main\resources\db\mysql\data.sql')
             ) }
}[$Target]

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

"reset-db: '$Target' resetado ($($tables.Count) tabelas, $($cfg.seeds.Count) seed(s))."
