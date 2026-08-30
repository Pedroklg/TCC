# Análise estatística dos resultados

Processa os `results/<alvo>/<timestamp>/*-raw.json` (k6) e gera tabelas, gráficos e
testes de comparação entre as arquiteturas.

```powershell
python analysis/analyze.py
# com descarte de aquecimento no cenário constante (seção 3.7), ex.: 30 s:
$env:WARMUP_SEC="30"; python analysis/analyze.py
```

## De onde vêm os números

O **`*-raw.json` é a fonte de verdade** — cada linha é uma requisição com tempo,
duração, status e endpoint. Dele calculamos **qualquer** percentil (p95/p99),
throughput, taxa de erro e séries temporais. O `*-summary.json` do k6 é só
conferência rápida (estimativas pontuais).

## Tratamento estatístico (seção 3.7)

- **Repetições:** rode com `run-all.ps1 -Reps N`. As métricas são calculadas
  **por repetição** (`tables/per_rep.csv`) e depois agregadas em **média ± IC 95%**
  (`tables/summary.csv`). Recomendado: **N = 5 a 10**.
- **Distribuições não-normais:** tempo de resposta é assimétrico (cauda à direita),
  então reportamos **mediana e percentis**, não só a média.
- **Comparação entre arquiteturas:** teste **Kruskal-Wallis** (global) +
  **Mann-Whitney** par a par com correção de **Bonferroni** (`tables/stats_tests.txt`).
  Não-paramétricos, adequados à distribuição dos dados.
- **Aquecimento:** no cenário constante, descartar os primeiros segundos
  (`WARMUP_SEC`) para medir regime estável. Em rampa/pico **não** se descarta.

## Gráficos gerados (`figures/`)

| Arquivo | Para quê |
|---|---|
| `bar_p95.png`, `bar_p99.png` | comparação direta do tempo de resposta (caudas) por cenário |
| `bar_throughput.png` | vazão (req/s) por arquitetura |
| `bar_error.png` | taxa de erro (%) |
| `box_<cenário>.png` | distribuição/dispersão do tempo de resposta |
| `ecdf_<cenário>.png` | comparação fina das caudas (proporção sob cada latência) |
| `timeseries_ramp.png` | **degradação** do p95 conforme a carga sobe |
| `timeseries_spike.png` | **saturação e recuperação** sob pico |

As barras trazem barra de erro = IC 95% (some com 1 repetição).

## Importante sobre a latência de rede (seção 3.4)

Como o k6 roda localmente e as apps na AWS, os valores **absolutos** incluem a
latência do enlace (registrada em `baseline-latency.txt`). A comparação é
**relativa** entre arquiteturas — desconte/mencione a base ao interpretar.

## Cold start (medição na AWS)

Quando houver dados de cold/warm start, acrescentar um gráfico dedicado
(barras/box do *Init Duration*: cold puro × SnapStart × warm).

## Calibração do ponto de saturação (piloto)

Roda antes da campanha definitiva e responde uma pergunta que o desenho não fecha
sozinho: se a taxa de pico não passar do teto de nenhuma arquitetura, a taxa de erro
sai zero nos três e deixa de discriminar. O piloto sobe cada braço, aplica uma rampa
de chegada em degraus geométricos e mede onde o throughput deixa de crescer.

```bash
# uma repetição por braço, sem captura de recursos nem de cold start
pwsh ./run-aws-experiment.ps1 -Calibrate -SkipCaptures

python analysis/calibration.py
```

Saídas: `tables/calibration_curve.csv` (curva por patamar), `tables/calibration_summary.csv`
(teto, ponto de saturação e onde o erro cruza 5% por braço) e `figures/calibration.png`.
O script imprime o `PEAK_RATE` sugerido para o cenário de pico.

O descarte de iterações é reportado, mas não distingue sozinho alvo lento de teto de
VUs: em modelo aberto os dois impedem o início de novas iterações. Confronte com
`vus_max` e `client-cpu.csv` da mesma bateria antes de concluir que o gerador limitou.

## Capturas na AWS

O `run-aws-experiment.ps1` chama estes scripts automaticamente. Para rodá-los à
mão (requer `aws configure` feito):

```powershell
# Uso de recursos na janela de medição -> results/resources/usage-<arq>.csv
.\analysis\cloudwatch-capture.ps1 -Start "2026-06-01T14:00:00Z" -End "2026-06-01T14:10:00Z" `
    -MonoInstanceId i-aaa -MysqlInstanceId i-bbb `
    -EcsCluster tcc-petclinic-micro `
    -EcsServices @('customers-service','vets-service','visits-service','api-gateway','config-server','discovery-server')

# Cold start × warm start por subcenário -> results/coldstart/measurements.csv
.\analysis\coldstart-capture.ps1 -Subscenario sem-otim `
    -Functions @('tcc-petclinic-cold-getAllOwners','tcc-petclinic-cold-getOwnerById') `
    -Reps 15 -WarmPerCold 5
.\analysis\coldstart-capture.ps1 -Subscenario snapstart -Qualifier live `
    -Functions @('tcc-petclinic-snap-getAllOwners','tcc-petclinic-snap-getOwnerById') `
    -Reps 15 -WarmPerCold 5

# Custo faturado no período -> results/resources/billing-usage-type.csv
# Roda DEPOIS do experimento: o Cost Explorer leva cerca de 24 h para consolidar,
# e a tag de alocação de custo precisa estar ativa ANTES do gasto (não é retroativa).
.\analysis\billing-capture.ps1 -Start 2026-08-27 -End 2026-08-31
```

O `coldstart-capture.ps1` precisa de permissão para `lambda:*` e
`logs:FilterLogEvents`.
