# Reseta o MySQL de um alvo LOCAL ao estado-semente (baseline), para que cada
# repetição de teste comece idêntica (seção 3.6). Estratégia: TRUNCATE de todas as
# tabelas + recarga dos data.sql oficiais (INSERT IGNORE com IDs fixos). As apps
# continuam de pé (sem cache de 2º nível; leem do banco a cada requisição).
#
# Uso: .\infra\reset-db.ps1 -Target mono|micro
#
# Na AWS o banco é remoto — o equivalente é aplicar os mesmos data.sql no MySQL
# da nuvem (ver docs/fase7-aws.md).

param(
  [Parameter(Mandatory)][ValidateSet('mono', 'micro')][string]$Target
)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
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
