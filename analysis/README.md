# Análise estatística dos resultados

Processa os `results/<alvo>/<timestamp>/*-raw.json` (k6) e gera tabelas, gráficos e
testes de comparação entre as arquiteturas.

```powershell
python analysis/analyze.py
# com descarte de aquecimento no cenário constante (seção 3.6), ex.: 30 s:
$env:WARMUP_SEC="30"; python analysis/analyze.py
```

## De onde vêm os números

O **`*-raw.json` é a fonte de verdade** — cada linha é uma requisição com tempo,
duração, status e endpoint. Dele calculamos **qualquer** percentil (p95/p99),
throughput, taxa de erro e séries temporais. O `*-summary.json` do k6 é só
conferência rápida (estimativas pontuais).

## Tratamento estatístico (seção 3.6)

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
