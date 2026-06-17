# Testes de carga (Grafana k6)

Scripts de injeção de carga para a comparação entre as três arquiteturas.
A carga de trabalho é **idêntica** entre os alvos; só muda a URL base e o mapa de
rotas (isolado em [lib/targets.js](lib/targets.js)).

## Carga de trabalho ([lib/workload.js](lib/workload.js))

Fluxo de uso **realista e correlacionado**, que exercita o ponto que **diferencia**
as arquiteturas:
1. lista owners (navegação) → `customers-service`;
2. abre a **ficha de um owner** (owner + pets + visits) — operação `ownerDetail`,
   **endpoint discriminante**:
   - monolito/serverless: resolve em processo (join no banco) — `GET /owners/{id}`;
   - microsserviços: o gateway **agrega** customers + visits (custo de rede entre
     serviços) — `GET /api/gateway/owners/{id}`;
3. ~`VISIT_RATIO` agenda visita em um pet daquele owner → `visits-service`;
4. reads leves (vets, pettypes); 5. ~`NEW_OWNER_RATIO` cadastra owner;
6. *think time* aleatório (`THINK_MIN`–`THINK_MAX`).

A latência da agregação sai isolada em `op_owner_detail_latency` (no piloto local:
~9 ms mono × ~30 ms micro — o custo da comunicação entre serviços).

## Cenários (Quadro 3 da metodologia)

| Arquivo | Cenário | Modelo | Perfil de carga |
|---|---|---|---|
| [scenario-constant.js](scenario-constant.js) | Carga constante | fechado (VUs) | nº fixo de usuários simultâneos |
| [scenario-ramp.js](scenario-ramp.js) | Rampa | fechado (VUs) | crescimento progressivo até um teto |
| [scenario-spike.js](scenario-spike.js) | Pico/estresse | **aberto** (taxa de chegada) | mantém req/s alvo p/ achar a saturação |

> Constante e rampa usam **modelo fechado** (`constant-vus`/`ramping-vus`) = "N
> usuários concorrentes", realista. O pico usa **modelo aberto**
> (`ramping-arrival-rate`): a carga oferecida não se auto-limita quando o sistema
> fica lento, então a saturação aparece de verdade. No pico, `rate` = iterações/s
> (cada iteração ≈ 2-4 requisições) e o think time é zero.

## Métricas coletadas (QP2 da RSL / seção 3.5)

As métricas padrão do k6 já cobrem a QP2:

| Métrica TCC | Métrica k6 |
|---|---|
| Tempo de resposta (média, **p95**, **p99**) | `http_req_duration` |
| Throughput (req/s) | `http_reqs` |
| Taxa de erro (%) | `http_req_failed` |

Operações específicas: `op_owner_detail_latency` (agregação) e `op_write_latency`.

## Como rodar

Selecione o alvo com `TARGET` (`mono` | `micro` | `serverless`). Localmente as
URLs padrão já apontam para as portas certas; na AWS, passe `BASE_URL`.

```powershell
# Bateria completa (3 cenários) — definitiva
.\load-tests\run-all.ps1 -Target mono -Reps 10 -ResetBetweenReps

# Validação rápida do pipeline (~1,5 min)
.\load-tests\run-all.ps1 -Target mono -Quick

# Um cenário isolado
k6 run -e TARGET=mono -e VUS=50 -e DURATION=5m load-tests/scenario-constant.js

# Contra a AWS (serverless), informando o endpoint do API Gateway
.\load-tests\run-all.ps1 -Target serverless -BaseUrl https://xxxx.execute-api.us-east-1.amazonaws.com/petclinic/api
```

### Flags do `run-all.ps1`

| Flag | Efeito |
|---|---|
| `-Reps N` | repete cada cenário N vezes (tratamento estatístico — seção 3.6) |
| `-ResetBetweenReps` | TRUNCATE+reseed do MySQL antes de cada rep (baseline idêntico; local) |
| `-Quick` | durações/VUs reduzidos só para validar o pipeline |

## Parâmetros (variáveis `-e`)

| Variável | Padrão | Usado em |
|---|---|---|
| `TARGET` / `BASE_URL` | `mono` / porta local | todos |
| `VUS` / `DURATION` | `50` / `5m` | constante |
| `MAX_VUS` | `200` | rampa |
| `BASE_RATE` / `PEAK_RATE` | `20` / `300` (iter/s) | pico (modelo aberto) |
| `PREALLOC_VUS` / `MAX_VUS` | `100` / `800` | pico |
| `VISIT_RATIO` / `NEW_OWNER_RATIO` | `0.2` / `0.05` | mix de escrita |
| `THINK_MIN` / `THINK_MAX` | `0.5` / `2.0` s | think time (0 no pico) |

> Os valores padrão são pontos de partida. Os números definitivos (VUs, taxas,
> durações) devem ser calibrados após o dry run e registrados no Capítulo 4.

## Serverless — cold start × warm start

O cold start não é medido por estes cenários genéricos: ele exige indução
controlada de novos ambientes de execução (seção 3.6). Isso será tratado em um
script dedicado quando a função Lambda estiver no ar (Fase 6 do setup).
