# Executa os 3 cenários k6 contra um alvo e salva os resultados em /results.
# Registra também a latência de base do enlace (exigência da seção 3.4 da metodologia)
# antes de cada bateria — relevante quando o alvo estiver na AWS.
#
# Uso:
#   .\load-tests\run-all.ps1 -Target mono                 # runs definitivos (longos)
#   .\load-tests\run-all.ps1 -Target mono -Quick          # validação rápida (~1,5 min/alvo)
#   .\load-tests\run-all.ps1 -Target serverless -BaseUrl https://abc123.execute-api.us-east-1.amazonaws.com/petclinic/api

param(
  [ValidateSet('mono', 'micro', 'serverless')]
  [string]$Target = 'mono',
  [string]$BaseUrl = '',
  [int]$Reps = 50,  # repetições por cenário (§3.6 — 50 execuções; amostra representativa)
  [string]$Label = '',  # nome da pasta de resultados (default = Target); use p/ subcenários
                        # serverless: 'serverless-cold' e 'serverless-snap'
  [switch]$Quick,  # durações/VUs reduzidos só para validar o pipeline de coleta
  [switch]$ResetBetweenReps  # reseta o MySQL (TRUNCATE+reseed) antes de cada rep (local)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Label) { $Label = $Target }
$outDir = Join-Path $root "results\$Label\$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Monta os argumentos -e comuns
$envArgs = @('-e', "TARGET=$Target")
if ($BaseUrl) { $envArgs += @('-e', "BASE_URL=$BaseUrl") }

# Overrides de carga por cenário. No modo -Quick reduzimos tudo só para validar
# que o pipeline de coleta funciona; os valores definitivos ficam nos defaults
# dos próprios scripts (constante 5m/50 VUs, rampa até 200 VUs, pico 20->300 iter/s — modelo aberto).
# O pico é modelo aberto (taxa de chegada), sem think time.
$overrides = @{ constant = @(); ramp = @(); spike = @('-e', 'THINK_MIN=0', '-e', 'THINK_MAX=0') }
if ($Quick) {
  if (-not $PSBoundParameters.ContainsKey('Reps')) { $Reps = 2 }  # validação: poucas repetições
  $overrides.constant = @('-e', 'VUS=10', '-e', 'DURATION=30s')
  $overrides.ramp     = @('-e', 'MAX_VUS=30', '-e', 'RAMP_UP=15s', '-e', 'HOLD=15s', '-e', 'RAMP_DOWN=10s')
  $overrides.spike   += @('-e', 'BASE_RATE=10', '-e', 'PEAK_RATE=60', '-e', 'PREALLOC_VUS=50', '-e', 'MAX_VUS=200',
                          '-e', 'PRE=10s', '-e', 'RISE=5s', '-e', 'PEAK_HOLD=20s', '-e', 'FALL=5s', '-e', 'POST=10s')
}

# --- Latência de base do enlace ---
# Deriva o host a partir da BASE_URL (ou usa localhost para os testes locais).
$probeHost = 'localhost'
if ($BaseUrl) { $probeHost = ([Uri]$BaseUrl).Host }
Write-Host "Medindo latência de base até $probeHost ..." -ForegroundColor Cyan
try {
  $ping = Test-Connection -ComputerName $probeHost -Count 5 -ErrorAction Stop
  $avg = ($ping | Measure-Object -Property ResponseTime -Average).Average
  "host=$probeHost avg_rtt_ms=$avg" | Out-File (Join-Path $outDir 'baseline-latency.txt')
  Write-Host "  RTT médio: $avg ms" -ForegroundColor Green
} catch {
  "host=$probeHost rtt=indisponivel ($($_.Exception.Message))" | Out-File (Join-Path $outDir 'baseline-latency.txt')
  Write-Host "  (ICMP indisponível — registrado mesmo assim)" -ForegroundColor Yellow
}

# Metadados do run (reprodutibilidade)
@{
  target = $Target; baseUrl = $BaseUrl; reps = $Reps; quick = [bool]$Quick
  timestamp = $stamp; k6 = (k6 version)
} | ConvertTo-Json | Out-File (Join-Path $outDir 'run-metadata.json')

# --- Cenários × repetições ---
$scenarios = @('constant', 'ramp', 'spike')
foreach ($s in $scenarios) {
  foreach ($rep in 1..$Reps) {
    $tag = 'rep{0:D2}' -f $rep
    Write-Host "`n=== Cenário: $s | $tag/$Reps (alvo: $Target) ===" -ForegroundColor Cyan
    if ($ResetBetweenReps -and $Target -in @('mono', 'micro')) {
      Write-Host "  reset do banco (baseline limpo para a repetição)..." -ForegroundColor DarkGray
      & (Join-Path $root 'infra\reset-db.ps1') -Target $Target | Out-Null
    }
    $summary = Join-Path $outDir "$s-$tag-summary.json"
    $raw = Join-Path $outDir "$s-$tag-raw.json"
    # k6 emite avisos (ex.: "Insufficient VUs") em stderr; no PowerShell 5.1 isso vira
    # NativeCommandError e, com $ErrorActionPreference='Stop', abortaria a bateria inteira.
    # Avisos não são falha: rodamos com EAP='Continue' e checamos só o código de saída.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    k6 run @envArgs @($overrides[$s]) `
      --summary-trend-stats "avg,min,med,max,p(90),p(95),p(99)" `
      --summary-export $summary `
      --out "json=$raw" `
      (Join-Path $PSScriptRoot "scenario-$s.js")
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($code -ne 0) { Write-Warning "k6 saiu com código $code em $s/$tag (limiar não atendido?); seguindo." }
  }
}

Write-Host "`nResultados salvos em: $outDir" -ForegroundColor Green
