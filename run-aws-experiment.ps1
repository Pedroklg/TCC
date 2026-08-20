<#
.SYNOPSIS
  Orquestra "instanciar => rodar => destruir" na AWS, uma arquitetura por vez.

.DESCRIPTION
  Para cada braço (mono, micro, serverless) o script:
    1. terraform apply -target=<recursos do braço>   (sobe SÓ aquele braço + comum + MySQL)
    2. espera o app responder 200 (health-gate)
    3. roda a(s) bateria(s) k6 (run-all.ps1, -Reps 10) sob um WATCHDOG de tempo
    4. captura recursos (CloudWatch) e, no serverless, cold start
    5. SEMPRE no finally: terraform destroy + verificação de que nada sobrou

  Janela POR ARQUITETURA: cada braço sobe e é destruído isoladamente -> MySQL fresco
  por braço (sem o banco crescer entre mono->micro->serverless) e janelas curtas. O
  destroy é um `terraform destroy` completo (sem -target): como só o braço atual está
  no state, ele limpa exatamente o que subiu.

  SEGURANÇA DE CUSTO (nível recomendado, sem reaper):
    - finally: destrói em qualquer saída (sucesso, erro ou Ctrl+C);
    - watchdog: se uma bateria k6 travar e passar do teto de tempo, o script aborta
      sozinho -> cai no finally -> destrói. Cobre o cenário de "k6 pendurado".
    - O Budget (módulo 00-budget) continua sendo o backstop financeiro.
  NÃO cobre o processo morrer "na marra" (queda de energia / notebook suspendendo).
  Antes de rodar sem supervisão: powercfg /change standby-timeout-ac 0

.EXAMPLE
  # Ensaio rápido do pipeline inteiro (sobe, roda pouco, captura, DESTRÓI):
  .\run-aws-experiment.ps1 -Quick

.EXAMPLE
  # Rodada definitiva, só o monolito e os microsserviços (deixa serverless p/ depois):
  .\run-aws-experiment.ps1 -Only mono,micro

.EXAMPLE
  # Tudo, 10 repetições por cenário (default):
  .\run-aws-experiment.ps1

.NOTES
  Pré-requisitos: aws configure feito; infra\terraform\terraform.tfvars preenchido;
  módulo 00-budget já aplicado (o budget é o primeiro recurso, por regra de custo do projeto).
#>
[CmdletBinding()]
param(
  [ValidateSet('mono', 'micro', 'serverless')]
  [string[]]$Only = @('mono', 'micro', 'serverless'),
  [int]$Reps = 10,                 # repetições por cenário (§3.7)
  [string]$DbSshKey = '',          # chave .pem do key pair -> reset do MySQL ao seed entre
                                   # repetições (mono/micro, §3.7). Sem ela: SEM reset (avisa).
  [switch]$Quick,                  # ensaio: poucas reps + timeouts curtos (valida o pipeline)
  [switch]$SkipCaptures,           # pula CloudWatch/cold start (só k6 + teardown)
  [switch]$SkipBudgetCheck,        # não exige o 00-budget aplicado (use com consciência)
  [int]$HealthTimeoutMin = 20,     # teto p/ o app subir e responder 200
  [int]$BatteryTimeoutMin = 240,   # watchdog por bateria k6 (backstop; 4h)
  [int]$ColdReps = 15,             # cold starts induzidos por função (serverless)
  [int]$WarmPerCold = 5,
  [string]$Prefix = 'tcc-petclinic'
)

$ErrorActionPreference = 'Stop'
# Recarrega o PATH (Machine+User) para encontrar CLIs instaladas nesta sessão (terraform/aws/k6).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$RepoRoot = $PSScriptRoot
$TfDir = Join-Path $RepoRoot 'infra\terraform'
$BudgetDir = Join-Path $TfDir '00-budget'
$RunAll = Join-Path $RepoRoot 'load-tests\run-all.ps1'
$CwCapture = Join-Path $RepoRoot 'analysis\cloudwatch-capture.ps1'
$ColdCapture = Join-Path $RepoRoot 'analysis\coldstart-capture.ps1'

if ($Quick) {
  if (-not $PSBoundParameters.ContainsKey('BatteryTimeoutMin')) { $BatteryTimeoutMin = 15 }
  if (-not $PSBoundParameters.ContainsKey('ColdReps')) { $ColdReps = 3 }
  # Invoke-Battery sempre passa -Reps, o que anula o default de -Quick no
  # run-all.ps1; reduzir aqui, senão o ensaio estoura o watchdog.
  if (-not $PSBoundParameters.ContainsKey('Reps')) { $Reps = 2 }
}

# Ordem canônica + config de cada braço.
# targets   = recursos a aplicar com -target. As regras de SG (mysql_from_*) são
#             ORFÃS no grafo (nada depende delas), então precisam vir explícitas,
#             senão o app sobe mas não alcança o MySQL.
# batteries = uma ou mais baterias k6 (serverless tem cold e snap).

# Como as regras de SG, estes recursos são órfãos no grafo e o -target não os
# alcança: rota de saída (user-data sem internet), política da role das EC2 (403
# ao baixar do S3) e política do agente CloudWatch (métrica de memória, §3.5).
$CommonTargets = @(
  'aws_route_table_association.public',
  'aws_iam_role_policy.ec2_s3',
  'aws_iam_role_policy_attachment.cw_agent'
)

$ArchConfig = [ordered]@{
  mono       = @{
    targets   = $CommonTargets + @(
      'aws_instance.monolith',
      'aws_security_group_rule.mysql_from_mono',
      'aws_security_group_rule.mysql_ssh'
    )
    batteries = @(
      @{ Target = 'mono'; Label = 'mono'; UrlOutput = 'monolith_base_url'; HealthPath = '/owners' }
    )
  }
  micro      = @{
    targets   = $CommonTargets + @(
      'aws_ecs_service.svc',
      'aws_iam_role_policy_attachment.ecs_exec', # órfão: sem ele o Fargate não puxa imagem/logs
      'aws_lb_listener.gateway',
      'aws_security_group_rule.mysql_from_micro',
      'aws_security_group_rule.micro_self',
      'aws_security_group_rule.mysql_ssh'
    )
    batteries = @(
      # Gate na agregação: /customer/owners responde assim que o Service Connect
      # resolve, mas a agregação espera o Eureka propagar (~60-90 s a mais).
      # Gatear na rota rápida contamina a primeira repetição.
      @{ Target = 'micro'; Label = 'micro'; UrlOutput = 'microservices_base_url'; HealthPath = '/gateway/owners/1' }
    )
  }
  serverless = @{
    targets   = $CommonTargets + @(
      'aws_apigatewayv2_route.fn',
      'aws_iam_role_policy_attachment.lambda_vpc', # órfão: sem ele a Lambda não cria ENI na VPC
      'aws_apigatewayv2_stage.default',
      'aws_lambda_permission.apigw',
      'aws_security_group_rule.mysql_from_lambda',
      'aws_security_group_rule.mysql_ssh'
    )
    batteries = @(
      @{ Target = 'serverless'; Label = 'serverless-cold'; UrlOutput = 'serverless_cold_base_url'; HealthPath = '/owners' },
      @{ Target = 'serverless'; Label = 'serverless-snap'; UrlOutput = 'serverless_snap_base_url'; HealthPath = '/owners' }
    )
  }
}

# ----------------------------------------------------------------------------- helpers

function Invoke-Terraform {
  param([string[]]$TfArgs)
  & terraform -chdir="$TfDir" @TfArgs
  if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs -join ' ') -> exit $LASTEXITCODE" }
}

function Get-TfOutput {
  param([string]$Name)
  $v = & terraform -chdir="$TfDir" output -raw $Name 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($v)) { throw "output '$Name' indisponível" }
  return $v.Trim()
}

function Wait-Health {
  param([string]$Url, [int]$TimeoutMin)
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  Write-Host "  health-gate: $Url (ate $TimeoutMin min)..." -ForegroundColor DarkCyan
  while ((Get-Date) -lt $deadline) {
    try {
      $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
      if ($r.StatusCode -eq 200) { Write-Host "  OK (200)" -ForegroundColor Green; return }
    }
    catch { }
    Start-Sleep -Seconds 10
  }
  throw "health-check excedeu $TimeoutMin min em $Url"
}

function Invoke-Battery {
  param([string]$Target, [string]$BaseUrl, [string]$Label, [int]$Reps, [switch]$Quick, [int]$TimeoutMin,
    [string]$DbHost = '', [string]$DbKey = '')
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunAll,
    '-Target', $Target, '-BaseUrl', $BaseUrl, '-Label', $Label, '-Reps', $Reps)
  if ($Quick) { $a += '-Quick' }
  if ($DbHost) { $a += @('-ResetBetweenReps', '-DbSshHost', $DbHost, '-DbSshKey', $DbKey) }
  Write-Host "  bateria '$Label' ($Reps reps) -> $BaseUrl" -ForegroundColor Cyan
  # Start-Process p/ ter o WATCHDOG (WaitForExit com timeout). -NoNewWindow herda o
  # console, então o output do k6 continua aparecendo ao vivo.
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -NoNewWindow -PassThru
  if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
    try { $p.Kill() } catch { }
    throw "WATCHDOG: bateria '$Label' passou de $TimeoutMin min - abortando (o finally vai destruir)"
  }
  # run-all tolera limiar k6 não atendido e sai 0; !=0 é anomalia, mas não aborta a sessão.
  if ($p.ExitCode -ne 0) { Write-Warning "run-all saiu com codigo $($p.ExitCode) em '$Label'; seguindo." }
}

function Confirm-Teardown {
  # Confirma que o state ficou vazio (destroy completo) + checagem por tag como rede de seguranca.
  $left = & terraform -chdir="$TfDir" state list 2>$null
  if ($left) {
    Write-Warning "ATENCAO: ainda ha recursos no state apos o destroy:`n$($left -join "`n")"
    Write-Warning ">>> Rode manualmente:  terraform -chdir=`"$TfDir`" destroy  <<<"
    return
  }
  $running = & aws ec2 describe-instances `
    --filters "Name=tag:Project,Values=$Prefix" "Name=instance-state-name,Values=pending,running" `
    --query "Reservations[].Instances[].InstanceId" --output text 2>$null
  if ($running) { Write-Warning "EC2 ainda em execucao com tag Project=${Prefix}: $running - confira o console!" }
  else { Write-Host "  teardown verificado: state vazio, sem EC2 ativa." -ForegroundColor Green }
}

function Get-IsoWindow { param([datetime]$T) return $T.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Invoke-Capture {
  param([string]$Arch, [datetime]$WinStart, [datetime]$WinEnd)
  if ($SkipCaptures) { return }
  $s = Get-IsoWindow $WinStart; $e = Get-IsoWindow $WinEnd
  try {
    switch ($Arch) {
      'mono' {
        $monoId = Get-TfOutput 'monolith_instance_id'
        $mysqlId = Get-TfOutput 'mysql_instance_id'
        & $CwCapture -Start $s -End $e -MonoInstanceId $monoId -MysqlInstanceId $mysqlId `
          -OutCsv 'results/resources/usage-mono.csv'
      }
      'micro' {
        $svcs = @('config-server', 'discovery-server', 'customers-service', 'vets-service', 'visits-service', 'api-gateway')
        & $CwCapture -Start $s -End $e -EcsCluster "$Prefix-micro" -EcsServices $svcs `
          -OutCsv 'results/resources/usage-micro.csv'
      }
      'serverless' {
        $fns = @('getAllOwners', 'getOwnerById', 'listVets', 'listPetTypes', 'createOwner', 'createVisit')
        $cold = $fns | ForEach-Object { "$Prefix-cold-$_" }
        $snap = $fns | ForEach-Object { "$Prefix-snap-$_" }
        & $CwCapture -Start $s -End $e -LambdaFunctions ($cold + $snap) -OutCsv 'results/resources/usage-serverless.csv'
        # Cold start: subconjunto representativo (2 funcoes) p/ economizar tempo/custo.
        & $ColdCapture -Subscenario 'sem-otim' `
          -Functions @("$Prefix-cold-getAllOwners", "$Prefix-cold-getOwnerById") `
          -Reps $ColdReps -WarmPerCold $WarmPerCold
        & $ColdCapture -Subscenario 'snapstart' -Qualifier 'live' `
          -Functions @("$Prefix-snap-getAllOwners", "$Prefix-snap-getOwnerById") `
          -Reps $ColdReps -WarmPerCold $WarmPerCold
      }
    }
  }
  catch {
    # Captura não é crítica: avisa e segue, sem impedir o teardown. Usa o
    # ErrorRecord inteiro porque falha de executável nativo vem com Message vazio.
    Write-Warning "captura de metricas ($Arch) falhou: $_ | em $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
  }
}

# ----------------------------------------------------------------------------- preflight

function Test-Preflight {
  if (-not $DbSshKey -and -not $Quick) {
    throw "Rodada definitiva exige -DbSshKey: o reset do MySQL ao seed entre repeticoes (§3.7) depende dele. Use -Quick para ensaiar sem reset."
  }
  foreach ($c in 'terraform', 'aws', 'k6') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "CLI '$c' nao encontrada no PATH." }
  }
  if (-not (Test-Path (Join-Path $TfDir 'terraform.tfvars'))) {
    throw "Falta infra\terraform\terraform.tfvars (copie do .example e preencha my_ip_cidr/key_name)."
  }
  & aws sts get-caller-identity *> $null
  if ($LASTEXITCODE -ne 0) { throw "Credenciais AWS ausentes/invalidas. Rode: aws configure" }

  if (-not $SkipBudgetCheck) {
    $b = & terraform -chdir="$BudgetDir" state list 2>$null
    if (-not $b) {
      throw "Modulo 00-budget NAO aplicado (regra do projeto: budget primeiro). Rode:`n" +
      "  terraform -chdir=`"$BudgetDir`" init; terraform -chdir=`"$BudgetDir`" apply`n" +
      "(ou -SkipBudgetCheck se ja garantiu o alerta de custo por fora.)"
    }
  }
  # Conta nova não tem a service-linked role do ECS e o CreateCluster falha.
  & aws iam get-role --role-name AWSServiceRoleForECS *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  criando service-linked role do ECS..." -ForegroundColor DarkCyan
    & aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com *> $null
    Start-Sleep -Seconds 10  # a role leva alguns segundos ate ficar utilizavel
  }

  Write-Host "Preflight OK." -ForegroundColor Green
}

# ----------------------------------------------------------------------------- main

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $RepoRoot "results\aws-run"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "$stamp.log") | Out-Null

$summary = @()
try {
  Test-Preflight
  @{
    timestamp = $stamp; reps = $Reps; quick = [bool]$Quick; only = $Only
    terraform = ((terraform version) -split "`n")[0]
    aws       = (aws --version 2>&1 | Out-String).Trim()
    k6        = (k6 version)
  } | ConvertTo-Json | Out-File (Join-Path $logDir "$stamp-versions.json") -Encoding utf8
  Invoke-Terraform @('init', '-input=false')

  $bTimeout = if ($Quick) { 15 } else { $BatteryTimeoutMin }

  foreach ($arch in $ArchConfig.Keys) {
    if ($arch -notin $Only) { continue }
    $cfg = $ArchConfig[$arch]
    Write-Host "`n===================== BRACO: $arch =====================" -ForegroundColor Magenta
    $createdMaybe = $false
    $status = 'ok'
    try {
      # 1. APPLY (so este braco). A partir daqui pode ter criado recurso -> destroy garantido.
      $createdMaybe = $true
      $targs = @('apply', '-input=false', '-auto-approve') + ($cfg.targets | ForEach-Object { "-target=$_" })
      Write-Host "apply: $($cfg.targets -join ', ')" -ForegroundColor DarkGray
      Invoke-Terraform $targs

      # 2..3. baterias (com health-gate antes de cada uma)
      # Reset do banco ao seed entre repetições (§3.7), nos três braços.
      $dbIp = if ($DbSshKey) { Get-TfOutput 'mysql_public_ip' } else { '' }
      $winStart = Get-Date
      foreach ($b in $cfg.batteries) {
        $base = Get-TfOutput $b.UrlOutput
        Wait-Health -Url ($base + $b.HealthPath) -TimeoutMin $HealthTimeoutMin
        Invoke-Battery -Target $b.Target -BaseUrl $base -Label $b.Label -Reps $Reps -Quick:$Quick -TimeoutMin $bTimeout `
          -DbHost $dbIp -DbKey $DbSshKey
      }
      $winEnd = Get-Date

      # 4. captura (nao-critica)
      Invoke-Capture -Arch $arch -WinStart $winStart -WinEnd $winEnd
    }
    catch {
      $status = "FALHOU: $($_.Exception.Message)"
      Write-Warning "Braco '$arch' $status"
    }
    finally {
      # 5. TEARDOWN — sempre, mesmo em erro/Ctrl+C. Destroy completo (so o braco atual no state).
      if ($createdMaybe) {
        Write-Host "teardown '$arch'..." -ForegroundColor Yellow
        try { Invoke-Terraform @('destroy', '-input=false', '-auto-approve'); Confirm-Teardown }
        catch { Write-Warning "DESTROY de '$arch' falhou: $($_.Exception.Message). RODE O DESTROY MANUAL!" }
      }
    }
    $summary += [pscustomobject]@{ arch = $arch; status = $status }
  }
}
finally {
  Write-Host "`n===================== RESUMO =====================" -ForegroundColor Magenta
  if ($summary) { $summary | Format-Table -AutoSize | Out-String | Write-Host }
  Write-Host "Apos as rodadas: python analysis\analyze.py ; python analysis\coldstart.py" -ForegroundColor DarkGray
  Stop-Transcript | Out-Null
}
