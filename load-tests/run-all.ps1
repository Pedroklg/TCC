# Executa os 3 cenários k6 contra um alvo e salva os resultados em /results.
# Registra também a latência de base do enlace (exigência da seção 3.4 da metodologia)
# antes de cada bateria — relevante quando o alvo estiver na AWS.
#
# Uso:
#   ./load-tests/run-all.ps1 -Target mono                 # runs definitivos (longos)
#   ./load-tests/run-all.ps1 -Target mono -Quick          # validação rápida (~1,5 min/alvo)
#   ./load-tests/run-all.ps1 -Target serverless -BaseUrl https://abc123.execute-api.us-east-1.amazonaws.com/petclinic/api

param(
  [ValidateSet('mono', 'micro', 'serverless')]
  [string]$Target = 'mono',
  [string]$BaseUrl = '',
  [int]$Reps = 10,  # repetições por cenário (§3.7 — 10 execuções; amostra representativa)
  [string]$Label = '',  # nome da pasta de resultados (default = Target); use p/ subcenários
                        # serverless: 'serverless-cold' e 'serverless-snap'
  [switch]$Quick,  # durações/VUs reduzidos só para validar o pipeline de coleta
  [switch]$Calibrate,  # roda só o cenário de calibração do ponto de saturação
  [switch]$ResetBetweenReps,  # reseta o MySQL ao seed antes de cada rep (§3.7)
  [string]$DbSshHost = '',  # AWS: IP público da EC2 do MySQL -> reset REMOTO via SSH
  [string]$DbSshKey = ''    # AWS: chave .pem do key pair (obrigatória com -DbSshHost)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Label) { $Label = $Target }
$outDir = Join-Path $root "results/$Label/$stamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Monta os argumentos -e comuns
$envArgs = @('-e', "TARGET=$Target")
if ($BaseUrl) { $envArgs += @('-e', "BASE_URL=$BaseUrl") }

# Overrides de carga por cenário. No modo -Quick reduzimos tudo só para validar
# que o pipeline de coleta funciona; os valores definitivos ficam nos defaults
# dos próprios scripts (constante 5m/50 VUs, rampa até 200 VUs, pico 20->300 iter/s — modelo aberto).
# O pico é modelo aberto (taxa de chegada), sem think time.
# Pico não cria owners: a listagem cresceria e saturaria o enlace do gerador.
$overrides = @{
  constant = @()
  ramp     = @()
  spike    = @('-e', 'THINK_MIN=0', '-e', 'THINK_MAX=0', '-e', 'NEW_OWNER_RATIO=0')
  # Calibração é modelo aberto como o pico, e pelo mesmo motivo não cria owners.
  # Também não registra visitas: é uma rampa contínua de dez minutos sem reset, e as
  # visitas acumuladas inflariam a ficha agregada ao longo do tempo, confundindo o
  # crescimento do payload com o da taxa de chegada.
  calibration = @('-e', 'THINK_MIN=0', '-e', 'THINK_MAX=0', '-e', 'NEW_OWNER_RATIO=0',
                  '-e', 'VISIT_RATIO=0')
}
if ($Calibrate -and -not $PSBoundParameters.ContainsKey('Reps')) { $Reps = 1 }
if ($Quick) {
  if (-not $PSBoundParameters.ContainsKey('Reps')) { $Reps = 2 }  # validação: poucas repetições
  $overrides.constant = @('-e', 'VUS=10', '-e', 'DURATION=30s')
  $overrides.ramp     = @('-e', 'MAX_VUS=30', '-e', 'RAMP_UP=15s', '-e', 'HOLD=15s', '-e', 'RAMP_DOWN=10s')
  $overrides.calibration += @('-e', 'START_RATE=10', '-e', 'MAX_RATE=60', '-e', 'STEPS=3',
                             '-e', 'STEP_HOLD=15s', '-e', 'STEP_RISE=5s', '-e', 'MAX_VUS=200')
  $overrides.spike   += @('-e', 'BASE_RATE=10', '-e', 'PEAK_RATE=60', '-e', 'PREALLOC_VUS=50', '-e', 'MAX_VUS=200',
                          '-e', 'PRE=10s', '-e', 'RISE=5s', '-e', 'PEAK_HOLD=20s', '-e', 'FALL=5s', '-e', 'POST=10s')
}

# --- Latência de base do enlace ---
# Handshake TCP, não ICMP: o ping exigiria uma regra ICMP no Security Group, e o
# TCP percorre o mesmo caminho que o k6 usa.
$probeHost = 'localhost'
$probePort = 80
if ($BaseUrl) {
  $u = [Uri]$BaseUrl
  $probeHost = $u.Host
  $probePort = $u.Port
}
# Medido por repetição, não por bateria: os três braços rodam em horários
# distintos ao longo da sessão, e o enlace vira covariável registrada.
function Measure-BaselineRtt {
  $rtts = @()
  foreach ($i in 1..5) {
    $c = [Net.Sockets.TcpClient]::new()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      if ($c.ConnectAsync($probeHost, $probePort).Wait(5000)) {
        $sw.Stop()
        $rtts += $sw.Elapsed.TotalMilliseconds
      }
    }
    catch { }
    finally { $c.Dispose() }
  }
  if (-not $rtts.Count) { return $null }
  # min é menos sensível a jitter e ao DNS da primeira conexão que a média
  return [pscustomobject]@{
    avg_rtt_ms = [math]::Round(($rtts | Measure-Object -Average).Average, 2)
    min_rtt_ms = [math]::Round(($rtts | Measure-Object -Minimum).Minimum, 2)
  }
}

# CPU do gerador (§3.4): amostrada em segundo plano durante cada bateria para
# confirmar que o cliente não se tornou o fator limitante.
function Start-CpuSampler {
  param([string]$Path, [string]$Scenario, [string]$Rep)
  Start-Job -ArgumentList $Path, $Scenario, $Rep -ScriptBlock {
    param($p, $s, $r)
    # /proc/stat acumula desde o boot: a ocupação é a diferença entre duas leituras.
    function Read-ProcStat {
      $v = (Get-Content /proc/stat -TotalCount 1) -split '\s+' |
        Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object { [double]$_ }
      return @{ idle = $v[3] + $v[4]; total = ($v | Measure-Object -Sum).Sum }
    }
    $prev = if ($IsLinux) { Read-ProcStat } else { $null }
    while ($true) {
      Start-Sleep -Seconds 5
      if ($IsLinux) {
        $cur = Read-ProcStat
        $dt = $cur.total - $prev.total
        $v = if ($dt -gt 0) { [math]::Round(100 * (1 - ($cur.idle - $prev.idle) / $dt), 1) } else { 0 }
        $prev = $cur
      }
      else {
        $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
      }
      "$s,$r,$v" | Add-Content -Path $p
    }
  }
}

$rttCsv = Join-Path $outDir 'baseline-latency.csv'
"scenario,rep,host,port,avg_rtt_ms,min_rtt_ms" | Out-File $rttCsv -Encoding utf8
$cpuCsv = Join-Path $outDir 'client-cpu.csv'
"scenario,rep,cpu_pct" | Out-File $cpuCsv -Encoding utf8

# Metadados do run (reprodutibilidade). -Encoding utf8: o default do PS 5.1 é
# UTF-16LE, ilegível para leitores JSON.
@{
  target    = $Target; baseUrl = $BaseUrl; reps = $Reps; quick = [bool]$Quick
  timestamp = $stamp; k6 = (k6 version)
} | ConvertTo-Json | Out-File (Join-Path $outDir 'run-metadata.json') -Encoding utf8

# --- Cenários × repetições ---
$scenarios = if ($Calibrate) { @('calibration') } else { @('constant', 'ramp', 'spike') }
foreach ($s in $scenarios) {
  foreach ($rep in 1..$Reps) {
    $tag = 'rep{0:D2}' -f $rep
    Write-Host "`n=== Cenário: $s | $tag/$Reps (alvo: $Target) ===" -ForegroundColor Cyan
    if ($ResetBetweenReps) {
      Write-Host "  reset do banco (baseline limpo para a repetição)..." -ForegroundColor DarkGray
      $resetArgs = @{ Target = $Target }
      if ($DbSshHost) { $resetArgs.SshHost = $DbSshHost; $resetArgs.SshKey = $DbSshKey }
      & (Join-Path $root 'infra/reset-db.ps1') @resetArgs | Out-Null
    }
    $rtt = Measure-BaselineRtt
    if ($rtt) {
      "$s,$rep,$probeHost,$probePort,$($rtt.avg_rtt_ms),$($rtt.min_rtt_ms)" | Out-File $rttCsv -Append -Encoding utf8
      Write-Host "  RTT TCP: media $($rtt.avg_rtt_ms) ms | min $($rtt.min_rtt_ms) ms" -ForegroundColor DarkGray
    }
    else {
      "$s,$rep,$probeHost,$probePort,," | Out-File $rttCsv -Append -Encoding utf8
      Write-Host "  (sonda TCP indisponivel)" -ForegroundColor Yellow
    }
    $cpuJob = Start-CpuSampler -Path $cpuCsv -Scenario $s -Rep $rep

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
    Stop-Job $cpuJob -ErrorAction SilentlyContinue
    Remove-Job $cpuJob -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { Write-Warning "k6 saiu com código $code em $s/$tag (limiar não atendido?); seguindo." }
  }
}

Write-Host "`nResultados salvos em: $outDir" -ForegroundColor Green
