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
# Fora do Windows os escopos Machine/User devolvem null e zerariam o PATH.
if (($null -eq $IsWindows) -or $IsWindows) {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutCsv) | Out-Null
$startEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
# Atribuir @() por um if devolve $null, e o splat de $null injeta um argumento
# vazio que o aws consome como o arquivo de saída, deslocando o real.
$qual = @()
if ($Qualifier) { $qual = @('--qualifier', $Qualifier) }
$payload = 'eyJwYXRoUGFyYW1ldGVycyI6eyJvd25lcklkIjoiMSIsInBldElkIjoiMSJ9fQ==' # base64 {"pathParameters":{"ownerId":"1","petId":"1"}}
$tmp = [IO.Path]::GetTempPath()
$outJson = Join-Path $tmp 'lambda-out.json'

# O PS 5.1 transforma stderr de executável nativo em erro terminante sem texto
# quando ErrorActionPreference='Stop'; checar o código de saída dá uma mensagem útil.
function Invoke-Aws {
  param([Parameter(ValueFromRemainingArguments)][string[]]$AwsArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & aws @AwsArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "aws $($AwsArgs -join ' ') -> exit ${LASTEXITCODE}: $($out -join ' ')"
    }
    return $out
  }
  finally { $ErrorActionPreference = $prev }
}

foreach ($fn in $Functions) {
  Write-Host "== $fn ==" -ForegroundColor Cyan

  # --environment SUBSTITUI o mapa inteiro: sem preservar o atual, a captura
  # apagaria MYSQL_URL e SPRING_CLOUD_FUNCTION_DEFINITION e quebraria a função.
  # Via arquivo JSON porque os valores contêm '=' e '&', que a sintaxe abreviada
  # não suporta.
  $baseVars = @{}
  $cfg = Invoke-Aws lambda get-function-configuration --function-name $fn --region $Region `
    --query 'Environment.Variables' --output json | ConvertFrom-Json
  if ($cfg) { $cfg.PSObject.Properties | ForEach-Object { $baseVars[$_.Name] = $_.Value } }
  $envFile = Join-Path $tmp "lambda-env-$fn.json"

  for ($r = 1; $r -le $Reps; $r++) {
    # Induz COLD: muda uma variável trivial -> novo ambiente de execução.
    # (SnapStart: publique nova versão e aponte o alias para obter um restore fresco.)
    $vars = $baseVars.Clone()
    $vars['COLD_NONCE'] = [Guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($envFile, (@{ Variables = $vars } | ConvertTo-Json -Compress -Depth 4))

    Invoke-Aws lambda update-function-configuration --function-name $fn --region $Region `
      --environment "file://$envFile" | Out-Null
    Invoke-Aws lambda wait function-updated --function-name $fn --region $Region | Out-Null

    # SnapStart: o alias aponta para uma VERSÃO publicada, e alterar a config do
    # $LATEST não a modifica — sem publicar e reapontar, as invocações caem sempre
    # no ambiente já restaurado e nenhum restore novo é medido.
    if ($Qualifier) {
      $ver = (((Invoke-Aws lambda publish-version --function-name $fn --region $Region `
              --query Version --output text) -join '') -replace '\s', '')
      Invoke-Aws lambda wait published-version-active --function-name $fn --qualifier $ver --region $Region | Out-Null
      Invoke-Aws lambda update-alias --function-name $fn --name $Qualifier `
        --function-version $ver --region $Region | Out-Null
    }

    # Cold + warms
    Invoke-Aws lambda invoke --function-name $fn @qual --region $Region --payload $payload `
      --cli-binary-format base64 $outJson | Out-Null
    for ($w = 1; $w -le $WarmPerCold; $w++) {
      Invoke-Aws lambda invoke --function-name $fn @qual --region $Region --payload $payload `
        --cli-binary-format base64 $outJson | Out-Null
    }
  }
}

Start-Sleep -Seconds 20  # deixa os logs chegarem ao CloudWatch

# Classifica cold × warm. O Init Duration não vem no REPORT: a AWS emite
# "INIT_REPORT Init Duration: X ms" como linha própria, antes do primeiro REPORT
# daquele ambiente. Só o Restore Duration do SnapStart aparece também no REPORT.
# Daí a correlação por stream em ordem cronológica.
$rows = @()
foreach ($fn in $Functions) {
  $lg = "/aws/lambda/$fn"
  $resp = Invoke-Aws logs filter-log-events --log-group-name $lg --region $Region `
    --start-time $startEpochMs --filter-pattern "REPORT" --output json | ConvertFrom-Json
  $events = @($resp.events) | Sort-Object logStreamName, timestamp

  $pendingInit = $null
  foreach ($e in $events) {
    $m = $e.message
    if ($m -match '^(INIT_REPORT|RESTORE_REPORT)') {
      if ($m -match '(?:Init|Restore) Duration:\s*([\d.]+)\s*ms') { $pendingInit = [double]$Matches[1] }
      continue
    }
    if ($m -notmatch '^REPORT') { continue }

    $dur = if ($m -match '(?<!Billed )(?<!Init )(?<!Restore )Duration:\s*([\d.]+)\s*ms') { [double]$Matches[1] } else { $null }
    if ($null -eq $dur) { continue }
    $billed = if ($m -match '(?<!Restore )Billed Duration:\s*([\d.]+)\s*ms') { [double]$Matches[1] } else { $null }
    $mem = if ($m -match 'Max Memory Used:\s*([\d.]+)\s*MB') { [double]$Matches[1] } else { $null }

    $init = $null
    if ($m -match 'Restore Duration:\s*([\d.]+)\s*ms') { $init = [double]$Matches[1] }
    elseif ($null -ne $pendingInit) { $init = $pendingInit }
    $pendingInit = $null

    $rows += [pscustomobject]@{
      subscenario = $Subscenario
      invocation  = if ($null -ne $init) { 'cold' } else { 'warm' }
      init_ms     = if ($null -ne $init) { $init } else { 0 }
      duration_ms = $dur
      billed_ms   = if ($null -ne $billed) { $billed } else { '' }
      mem_mb      = if ($null -ne $mem) { $mem } else { '' }
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
