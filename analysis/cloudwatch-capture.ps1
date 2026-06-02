# Captura uso de recursos (CPU/memória) do CloudWatch na janela de medição (AWS).
# Métrica comparável entre EC2 e Fargate: utilização de CPU (%). Para o Lambda,
# coleta-se a duração (proxy de uso); a memória usada está na linha REPORT dos logs
# (ver coldstart-capture.ps1). Saída no formato lido por analyze.py::resource_usage.
#
# Uso (exemplo):
#   .\analysis\cloudwatch-capture.ps1 -Start "2026-06-01T14:00:00Z" -End "2026-06-01T14:10:00Z" `
#       -MonoInstanceId i-aaa -MysqlInstanceId i-bbb `
#       -EcsCluster tcc-petclinic-micro -EcsServices @('customers-service','vets-service','visits-service','api-gateway','config-server','discovery-server')
#
# Requer aws configure feito. Obs.: a MEMÓRIA da EC2 só aparece no CloudWatch com o
# CloudWatch Agent instalado; sem ele, registra-se apenas CPU para a EC2.

param(
  [Parameter(Mandatory)][string]$Start,   # ISO-8601 UTC
  [Parameter(Mandatory)][string]$End,
  [string]$MonoInstanceId = '',
  [string]$MysqlInstanceId = '',
  [string]$EcsCluster = '',
  [string[]]$EcsServices = @(),
  [string[]]$LambdaFunctions = @(),
  [int]$PeriodSec = 60,
  [string]$Region = 'us-east-1',
  [string]$OutCsv = 'results/resources/usage.csv'
)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
New-Item -ItemType Directory -Force -Path (Split-Path $OutCsv) | Out-Null

function Stat($ns, $metric, $dimName, $dimVal) {
  $j = aws cloudwatch get-metric-statistics --region $Region --namespace $ns --metric-name $metric `
    --dimensions "Name=$dimName,Value=$dimVal" --start-time $Start --end-time $End `
    --period $PeriodSec --statistics Average Maximum --output json 2>$null | ConvertFrom-Json
  if (-not $j.Datapoints) { return @{ avg = $null; max = $null } }
  $avg = ($j.Datapoints | Measure-Object -Property Average -Average).Average
  $max = ($j.Datapoints | Measure-Object -Property Maximum -Maximum).Maximum
  return @{ avg = [math]::Round($avg, 1); max = [math]::Round($max, 1) }
}

$rows = @()
function Add($arch, $comp, $cpu, $mem) {
  $rows += [pscustomobject]@{
    architecture = $arch; component = $comp
    cpu_avg_pct = $cpu.avg; cpu_max_pct = $cpu.max
    mem_avg_pct = $mem.avg; mem_max_pct = $mem.max
  }
}

# Monolito (EC2): CPU. (Memória só com CloudWatch Agent.)
if ($MonoInstanceId) { Add 'Monolito' 'ec2' (Stat 'AWS/EC2' 'CPUUtilization' 'InstanceId' $MonoInstanceId) @{avg = $null; max = $null } }
# MySQL (comum) — informativo
if ($MysqlInstanceId) { Add 'MySQL' 'ec2' (Stat 'AWS/EC2' 'CPUUtilization' 'InstanceId' $MysqlInstanceId) @{avg = $null; max = $null } }

# Microsserviços (ECS/Fargate): CPU e memória por serviço.
foreach ($svc in $EcsServices) {
  $cpu = aws cloudwatch get-metric-statistics --region $Region --namespace 'AWS/ECS' --metric-name 'CPUUtilization' `
    --dimensions "Name=ClusterName,Value=$EcsCluster" "Name=ServiceName,Value=$svc" --start-time $Start --end-time $End `
    --period $PeriodSec --statistics Average Maximum --output json 2>$null | ConvertFrom-Json
  $mem = aws cloudwatch get-metric-statistics --region $Region --namespace 'AWS/ECS' --metric-name 'MemoryUtilization' `
    --dimensions "Name=ClusterName,Value=$EcsCluster" "Name=ServiceName,Value=$svc" --start-time $Start --end-time $End `
    --period $PeriodSec --statistics Average Maximum --output json 2>$null | ConvertFrom-Json
  $c = if ($cpu.Datapoints) { @{avg = [math]::Round(($cpu.Datapoints | Measure-Object Average -Average).Average, 1); max = [math]::Round(($cpu.Datapoints | Measure-Object Maximum -Maximum).Maximum, 1) } } else { @{avg = $null; max = $null } }
  $m = if ($mem.Datapoints) { @{avg = [math]::Round(($mem.Datapoints | Measure-Object Average -Average).Average, 1); max = [math]::Round(($mem.Datapoints | Measure-Object Maximum -Maximum).Maximum, 1) } } else { @{avg = $null; max = $null } }
  Add 'Microsserviços' $svc $c $m
}

# Serverless (Lambda): duração média (proxy de uso de CPU); memória usada nos logs.
foreach ($fn in $LambdaFunctions) {
  $d = Stat 'AWS/Lambda' 'Duration' 'FunctionName' $fn
  $rows += [pscustomobject]@{ architecture = 'Serverless'; component = $fn; cpu_avg_pct = $null; cpu_max_pct = $null; mem_avg_pct = $null; mem_max_pct = $null; dur_avg_ms = $d.avg; dur_max_ms = $d.max }
}

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8
"Uso de recursos salvo em $OutCsv ($($rows.Count) componentes). Depois: python analysis/analyze.py"
