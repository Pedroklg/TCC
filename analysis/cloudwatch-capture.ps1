# Captura uso de recursos do CloudWatch na janela de medição (AWS), no formato
# lido por analyze.py::resource_usage.
#   EC2      CPU (AWS/EC2) + memória (CWAgent, instalado pelo user-data)
#   ECS      CPU e memória por serviço
#   Lambda   duração como proxy de uso; a memória sai da linha REPORT
#
# Conta também, na mesma janela, a fração de invocações a frio por subcenário
# (f_fria, §3.6) -> results/resources/lambda_cold_fraction.csv.
#
# Como rodar: ver analysis/README.md.

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
# Cultura invariante: Export-Csv usa a cultura corrente e em pt-BR gravaria
# "24,1", que o pandas lê como texto.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
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
  # $script: é obrigatório — dentro de uma função, "$rows +=" grava numa cópia
  # local e a linha se perde, gerando um CSV vazio sem erro.
  $script:rows += [pscustomobject]@{
    architecture = $arch; component = $comp
    cpu_avg_pct = $cpu.avg; cpu_max_pct = $cpu.max
    mem_avg_pct = $mem.avg; mem_max_pct = $mem.max
  }
}

# Monolito (EC2): CPU (AWS/EC2) + memória (CWAgent, instalado pelo user-data).
if ($MonoInstanceId) { Add 'Monolito' 'ec2' (Stat 'AWS/EC2' 'CPUUtilization' 'InstanceId' $MonoInstanceId) (Stat 'CWAgent' 'mem_used_percent' 'InstanceId' $MonoInstanceId) }
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

# Consumo POR CONTÊINER (Container Insights): as métricas AWS/ECS param no nível da
# tarefa, e o proxy do Service Connect divide com a aplicação o mesmo orçamento de
# CPU/memória. CpuUtilized vem em unidades de CPU (1024 = 1 vCPU) e MemoryUtilized em MB.
if ($EcsCluster) {
  $lg = "/aws/ecs/containerinsights/$EcsCluster/performance"
  $qs = 'filter Type = "Container" | stats avg(CpuUtilized) as cpu_units_avg, ' +
  'max(CpuUtilized) as cpu_units_max, avg(MemoryUtilized) as mem_mb_avg, ' +
  'max(MemoryUtilized) as mem_mb_max by ContainerName'
  # O Container Insights leva alguns minutos para descarregar os dados no grupo de
  # logs: consultar logo apos a bateria devolve resultado vazio, entao a consulta e
  # reemitida ate vir preenchida.
  $res = $null
  foreach ($attempt in 1..5) {
    $qid = aws logs start-query --log-group-name $lg --region $Region `
      --start-time ([DateTimeOffset]::Parse($Start).ToUnixTimeSeconds()) `
      --end-time ([DateTimeOffset]::Parse($End).ToUnixTimeSeconds()) `
      --query-string $qs --query queryId --output text 2>$null
    if ($qid) {
      foreach ($i in 1..15) {
        Start-Sleep -Seconds 2
        $r = aws logs get-query-results --query-id $qid --region $Region --output json 2>$null | ConvertFrom-Json
        if ($r.status -eq 'Complete') { $res = $r.results; break }
      }
    }
    if ($res -and @($res).Count -gt 0) { break }
    if ($attempt -lt 5) {
      Write-Host "  Container Insights ainda sem dados; nova tentativa em 60 s..." -ForegroundColor DarkGray
      Start-Sleep -Seconds 60
    }
  }
  if ($res -and @($res).Count -gt 0) {
    $ctrCsv = Join-Path (Split-Path $OutCsv) 'containers-micro.csv'
    $res | ForEach-Object {
      $o = [ordered]@{}
      $_ | ForEach-Object { $o[$_.field] = $_.value }
      [pscustomobject]$o
    } | Export-Csv -Path $ctrCsv -NoTypeInformation -Encoding utf8
    "Consumo por conteiner salvo em $ctrCsv"
  }
  else { Write-Warning "Container Insights sem dados na janela apos 5 tentativas" }
}

# Serverless (Lambda): duração média (proxy de uso de CPU); memória usada nos logs.
foreach ($fn in $LambdaFunctions) {
  $d = Stat 'AWS/Lambda' 'Duration' 'FunctionName' $fn
  $rows += [pscustomobject]@{ architecture = 'Serverless'; component = $fn; cpu_avg_pct = $null; cpu_max_pct = $null; mem_avg_pct = $null; mem_max_pct = $null; dur_avg_ms = $d.avg; dur_max_ms = $d.max }
}

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8
"Uso de recursos salvo em $OutCsv ($($rows.Count) componentes). Depois: python analysis/analyze.py"

# --- f_fria (§3.6): fração de invocações a frio OBSERVADA na janela de teste ---
# Conta as linhas REPORT com Init/Restore Duration vs o total, por subcenário
# (nome da função contém -cold- ou -snap-). Alimenta analysis/cost-model.py.
if ($LambdaFunctions) {
  $t0 = [DateTimeOffset]::Parse($Start).ToUnixTimeMilliseconds()
  $t1 = [DateTimeOffset]::Parse($End).ToUnixTimeMilliseconds()
  $frac = @{}
  foreach ($fn in $LambdaFunctions) {
    $sub = if ($fn -match '-snap-') { 'snapstart' } elseif ($fn -match '-cold-') { 'sem-otim' } else { 'desconhecido' }
    if (-not $frac.ContainsKey($sub)) { $frac[$sub] = @{ total = 0; cold = 0 } }
    $events = aws logs filter-log-events --log-group-name "/aws/lambda/$fn" --region $Region `
      --start-time $t0 --end-time $t1 --filter-pattern "REPORT" --query "events[].message" --output json 2>$null | ConvertFrom-Json
    foreach ($m in $events) {
      $frac[$sub].total++
      if ($m -match 'Init Duration:|Restore Duration:') { $frac[$sub].cold++ }
    }
  }
  $fracCsv = Join-Path (Split-Path $OutCsv) 'lambda_cold_fraction.csv'
  $fracRows = foreach ($k in $frac.Keys) {
    $t = $frac[$k].total; $c = $frac[$k].cold
    [pscustomobject]@{ subscenario = $k; invocations = $t; cold = $c
      cold_fraction = $(if ($t -gt 0) { [math]::Round($c / $t, 4) } else { $null }) }
  }
  $fracRows | Export-Csv -Path $fracCsv -NoTypeInformation -Encoding utf8
  "Fração de cold starts na janela salva em $fracCsv"
}
