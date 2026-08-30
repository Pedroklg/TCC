# Captura o custo faturado no período do experimento (AWS Cost Explorer), para a
# validação empírica do modelo de custo (§3.6) -> results/resources/billing-usage-type.csv.
#
# O detalhamento é por tipo de uso, e não por serviço: é o tipo de uso que carrega a
# quantidade faturada (horas, GB-segundo, requisições) e permite dividir o custo pelo
# preço unitário para confrontá-lo com a Tabela de preços da monografia.
#
# Exige que a tag de alocação de custo esteja ATIVA antes do gasto: a ativação não é
# retroativa, e o que foi consumido antes dela aparece sem tag.
#
# Cada consulta ao Cost Explorer é tarifada (USD 0,01 por requisição na data desta análise).
#
# Como rodar: ver analysis/README.md.

param(
  [Parameter(Mandatory)][string]$Start,   # AAAA-MM-DD (inclusivo)
  [Parameter(Mandatory)][string]$End,     # AAAA-MM-DD (exclusivo)
  [string]$Region = 'us-east-1',
  [string]$OutCsv = 'results/resources/billing-usage-type.csv'
)
$ErrorActionPreference = 'Stop'
# Cultura invariante: Export-Csv usa a cultura corrente e em pt-BR gravaria
# "0,085", que o pandas lê como texto.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
# Fora do Windows os escopos Machine/User devolvem null e zerariam o PATH.
if (($null -eq $IsWindows) -or $IsWindows) {
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
New-Item -ItemType Directory -Force -Path (Split-Path $OutCsv) | Out-Null

# Sem este filtro os créditos entram como valores negativos e anulam o uso, devolvendo
# um total zerado que esconde o consumo real.
$soUso = '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'

$j = aws ce get-cost-and-usage --region $Region `
  --time-period "Start=$Start,End=$End" --granularity DAILY `
  --metrics UnblendedCost UsageQuantity `
  --group-by Type=DIMENSION,Key=USAGE_TYPE --filter $soUso `
  --output json | ConvertFrom-Json

$rows = foreach ($r in $j.ResultsByTime) {
  foreach ($g in $r.Groups) {
    $c = [double]$g.Metrics.UnblendedCost.Amount
    if ($c -le 0.000001) { continue }
    [pscustomobject]@{
      data        = $r.TimePeriod.Start
      usage_type  = $g.Keys[0]
      custo_usd   = [math]::Round($c, 6)
      quantidade  = [double]$g.Metrics.UsageQuantity.Amount
      unidade     = $g.Metrics.UsageQuantity.Unit
      estimado    = $r.Estimated
    }
  }
}
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8
"Custo faturado salvo em $OutCsv ($($rows.Count) linhas, total USD $([math]::Round(($rows | Measure-Object custo_usd -Sum).Sum, 2)))"

# Créditos à parte: registra quanto do uso foi absorvido, para que o total faturado
# não seja confundido com desembolso.
$k = aws ce get-cost-and-usage --region $Region `
  --time-period "Start=$Start,End=$End" --granularity MONTHLY --metrics UnblendedCost `
  --group-by Type=DIMENSION,Key=RECORD_TYPE --output json | ConvertFrom-Json
foreach ($r in $k.ResultsByTime) {
  foreach ($g in $r.Groups) {
    "  {0,-10} USD {1,10:N4}" -f $g.Keys[0], [double]$g.Metrics.UnblendedCost.Amount
  }
}
"Depois: python analysis/cost-model.py"
