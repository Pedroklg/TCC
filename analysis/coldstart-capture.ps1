# Captura cold start × warm start de um subcenário serverless na AWS: induz cold
# starts, invoca, e extrai das linhas REPORT do CloudWatch Logs o Init/Restore
# Duration, o Billed Duration (modelo de custo, §3.6) e o Max Memory Used.
#
# Saída lida por coldstart.py:
#   subscenario,invocation,init_ms,duration_ms,billed_ms,mem_mb
#
# Como rodar: ver analysis/README.md.

param(
  [Parameter(Mandatory)][ValidateSet('sem-otim', 'snapstart')][string]$Subscenario,
  [Parameter(Mandatory)][string[]]$Functions,
  [string]$Qualifier = '',            # alias/versão (ex.: 'live' para SnapStart)
  [int]$Reps = 15,                     # nº de cold starts induzidos por função
  [int]$WarmPerCold = 5,               # invocações aquecidas após cada cold
  [string]$Region = 'us-east-1',
  [string]$OutCsv = 'results/coldstart/measurements.csv'
)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

New-Item -ItemType Directory -Force -Path (Split-Path $OutCsv) | Out-Null
$startEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$qual = if ($Qualifier) { @('--qualifier', $Qualifier) } else { @() }
$payload = 'eyJwYXRoUGFyYW1ldGVycyI6eyJvd25lcklkIjoiMSIsInBldElkIjoiMSJ9fQ==' # base64 {"pathParameters":{"ownerId":"1","petId":"1"}}

foreach ($fn in $Functions) {
  Write-Host "== $fn ==" -ForegroundColor Cyan
  for ($r = 1; $r -le $Reps; $r++) {
    # Induz COLD: muda uma variável trivial -> novo ambiente de execução.
    # (SnapStart: publique nova versão e aponte o alias para obter um restore fresco.)
    $nonce = [Guid]::NewGuid().ToString()
    aws lambda update-function-configuration --function-name $fn --region $Region `
      --environment "Variables={COLD_NONCE=$nonce}" 2>$null | Out-Null
    aws lambda wait function-updated --function-name $fn --region $Region 2>$null

    # Cold + warms
    aws lambda invoke --function-name $fn @qual --region $Region --payload $payload `
      --cli-binary-format base64 /tmp/out.json 2>$null | Out-Null
    for ($w = 1; $w -le $WarmPerCold; $w++) {
      aws lambda invoke --function-name $fn @qual --region $Region --payload $payload `
        --cli-binary-format base64 /tmp/out.json 2>$null | Out-Null
    }
  }
}

Start-Sleep -Seconds 20  # deixa os logs chegarem ao CloudWatch

# Extrai as linhas REPORT e classifica cold (tem Init/Restore Duration) × warm.
$rows = @()
foreach ($fn in $Functions) {
  $lg = "/aws/lambda/$fn"
  $events = aws logs filter-log-events --log-group-name $lg --region $Region `
    --start-time $startEpochMs --filter-pattern "REPORT" --query "events[].message" --output json 2>$null | ConvertFrom-Json
  foreach ($m in $events) {
    $dur = if ($m -match '(?<!Billed )(?<!Init )(?<!Restore )Duration:\s*([\d.]+)\s*ms') { [double]$Matches[1] } else { $null }
    $billed = if ($m -match 'Billed Duration:\s*([\d.]+)\s*ms') { [double]$Matches[1] } else { $null }
    $init = $null
    if ($m -match 'Init Duration:\s*([\d.]+)\s*ms') { $init = [double]$Matches[1] }
    elseif ($m -match 'Restore Duration:\s*([\d.]+)\s*ms') { $init = [double]$Matches[1] }
    $mem = if ($m -match 'Max Memory Used:\s*([\d.]+)\s*MB') { [double]$Matches[1] } else { $null }
    $inv = if ($init) { 'cold' } else { 'warm' }
    if ($null -ne $dur) {
      $initVal = if ($init) { $init } else { 0 }
      $billedVal = if ($null -ne $billed) { $billed } else { '' }
      $memVal = if ($null -ne $mem) { $mem } else { '' }
      $rows += [pscustomobject]@{ subscenario = $Subscenario; invocation = $inv; init_ms = $initVal; duration_ms = $dur; billed_ms = $billedVal; mem_mb = $memVal }
    }
  }
}

# Anexa ao CSV (cria cabeçalho se novo).
if (-not (Test-Path $OutCsv)) { "subscenario,invocation,init_ms,duration_ms,billed_ms,mem_mb" | Out-File $OutCsv -Encoding utf8 }
$rows | ForEach-Object { "$($_.subscenario),$($_.invocation),$($_.init_ms),$($_.duration_ms),$($_.billed_ms),$($_.mem_mb)" } | Out-File $OutCsv -Append -Encoding utf8

$cold = ($rows | Where-Object invocation -eq 'cold').Count
$warm = ($rows | Where-Object invocation -eq 'warm').Count
"Capturado [$Subscenario]: $cold cold, $warm warm -> $OutCsv"
"Depois rode: python analysis/coldstart.py"
