# PetClinic — Comparação de Arquiteturas (Monolito × Microsserviços × Serverless)

Artefatos de um **Trabalho de Conclusão de Curso (TCC)** de Engenharia de Software
que compara empiricamente **desempenho, escalabilidade, uso de recursos, custo e
complexidade operacional** de três estilos arquiteturais, usando o benchmark
**Spring PetClinic** sob testes de carga com **Grafana k6**.

> **Status:** campanha concluída na AWS em 28–29/ago/2026 — 4 braços × 3 cenários ×
> 10 repetições, 3.687.822 requisições, nenhuma repetição descartada. Os resultados
> estão resumidos abaixo. A infraestrutura foi destruída ao fim de cada janela.

> Este repositório contém **scripts de carga, a versão serverless, ferramentas de
> análise e a infraestrutura (IaC)**. Vários comentários no código referenciam
> decisões e seções da metodologia do TCC — propositalmente, para ligar o código ao
> texto. O texto da monografia não é versionado aqui.

## As três arquiteturas

| Arquitetura           | Implementação                                                                                | Plataforma AWS (Terraform)                                   |
| --------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **Monolito**          | `spring-petclinic-rest` oficial (JAR único)                                                  | EC2 c5.large — 2 vCPU / 4 GB                                 |
| **Microsserviços**    | `spring-petclinic-microservices` oficial (serviços decompostos)                              | ECS Fargate + Service Connect — 6 tarefas somando 2 vCPU / 4 GB |
| **Serverless (FaaS)** | domínio refatorado em funções via **spring-cloud-function** (ver [serverless/](serverless/)) | Lambda + API Gateway (2 subcenários: cold start × SnapStart) |

Stack: Java 17, Spring Boot 4.0.6, MySQL 8.4. Serverless: spring-cloud-function 5.0.x.
As três usam o **mesmo domínio**, o **mesmo SGBD** e a **mesma capacidade contratada**,
de modo que as diferenças observadas decorram do estilo arquitetural.

## Resultados

Medianas do tempo de resposta em regime estável, capacidade sob pico (modelo aberto) e
eficiência por vCPU efetivamente consumida:

| Arquitetura              | Mediana (constante) | Vazão sustentada | Vazão útil | req/vCPU-s |
| ------------------------ | ------------------: | ---------------: | ---------: | ---------: |
| Monolito                 |              6,8 ms |     213,1 req/s  | 213,0 req/s |       80,8 |
| Microsserviços           |            286,0 ms |     221,3 req/s  | **124,3 req/s** |   85,4 |
| Serverless (sem otim.)   |             36,3 ms |     421,1 req/s  | 420,9 req/s |        1,4 |
| Serverless (SnapStart)   |             37,4 ms |     418,8 req/s  | 418,5 req/s |        1,4 |

Alguns achados que os números sozinhos não mostram:

- **As três degradam de modos distintos.** O monolito degrada em *tempo* (0% de erro sob
  pico, 100% das respostas agregadas completas); os microsserviços degradam em *conteúdo*
  — o disjuntor do gateway responde HTTP 200 com a lista de visitas vazia em 91,4% dos
  casos, o que o monitoramento por taxa de erro não detecta; o serverless degrada na
  *borda da elasticidade*, com falhas concentradas na primeira rajada.
- Por isso a tabela reporta **vazão útil** (desconta respostas incompletas) ao lado da
  vazão total: é ela que inverte a posição dos microsserviços sob pico.
- **Cold start:** 12,9 s de resposta fria sem otimização contra 765 ms de inicialização
  com SnapStart (fator de 13,1); invocação aquecida idêntica nos dois subcenários.
- **Custo:** o serverless é mais barato até cerca de 6 req/s contínuos, mas custou 94×
  o monolito por requisição quando mantido próximo da saturação. Os preços do modelo
  foram validados contra a fatura real (desvio nulo em 7 de 9 itens).

Os `results/` brutos (~16 GB de JSON do k6) não são versionados; o pipeline de análise
regenera todas as tabelas e figuras a partir deles.

## Estrutura do repositório

```
.
├── run-aws-experiment.ps1   # roda o experimento na AWS por arquitetura (apply → k6 → captura → destroy)
├── serverless/        # app FaaS (spring-cloud-function) — reúsa o domínio do monolito
├── load-tests/        # cenários k6 (constante, rampa, pico) + workload + runner
├── analysis/          # análise das métricas, cold start, calibração, modelo de custo
└── infra/
    ├── docker-compose.mysql.yml            # MySQL compartilhado (local)
    ├── docker-compose.microservices.yml    # stack de microsserviços (local)
    ├── reset-db.ps1                        # reset do banco ao baseline entre repetições
    ├── terraform/                          # IaC da AWS (EC2, ECS, Lambda, API GW, Budget) + README
    └── terraform-runner/                   # EC2 geradora de carga, na mesma região (state próprio)
```

> Os repositórios **oficiais** do PetClinic (monolito e microsserviços) **não** são
> versionados aqui — são clonados em `apps/` (ver abaixo).

O gerador de carga roda **na mesma região** dos alvos, e não na máquina do autor: a WAN
somava cerca de 140 ms por requisição e comprimia as diferenças arquiteturais. Isso mede
o custo arquitetural, não a experiência de um usuário distante. Ver
[infra/terraform-runner/README.md](infra/terraform-runner/README.md).

## Pré-requisitos

- Docker Desktop · JDK 17 (Temurin) · [Grafana k6](https://k6.io)
- Python 3 com `pandas numpy matplotlib scipy` (para a análise)
- Para a AWS: Terraform, AWS CLI, AWS SAM CLI (este para validar a serverless localmente)

## Setup local

### 1. Clonar os benchmarks oficiais

```bash
git clone https://github.com/spring-petclinic/spring-petclinic-rest.git           apps/monolith
git clone https://github.com/spring-petclinic/spring-petclinic-microservices.git  apps/microservices
```

### 2. Banco + monolito

```powershell
docker compose -f infra/docker-compose.mysql.yml up -d
cd apps/monolith ; .\mvnw.cmd spring-boot:run "-Dspring-boot.run.profiles=mysql,spring-data-jpa"
# valida: curl http://localhost:9966/petclinic/api/owners
```

### 3. Microsserviços

```powershell
docker compose -f infra/docker-compose.microservices.yml up -d
# valida pelo gateway: curl http://localhost:8080/api/customer/owners
```

### 4. Serverless (FaaS)

Reúsa o domínio do monolito como biblioteca — ver [serverless/README.md](serverless/README.md):

```powershell
cd apps/monolith ; .\mvnw.cmd -DskipTests install   # publica o domínio no .m2
cd ../../serverless ; .\mvnw.cmd -DskipTests package # gera o uber-jar do Lambda
sam local start-api                                  # valida via API Gateway local
```

## Testes de carga e análise

```powershell
# bateria nos 3 cenários (constante, rampa, pico), com repetições
.\load-tests\run-all.ps1 -Target mono       -Reps 10 -ResetBetweenReps
.\load-tests\run-all.ps1 -Target micro      -Reps 10 -ResetBetweenReps
.\load-tests\run-all.ps1 -Target serverless -Reps 10 -ResetBetweenReps

# análise: tabelas, gráficos e testes estatísticos
$env:WARMUP_SEC="60"; python analysis/analyze.py    # desempenho, vazão útil, recursos
python analysis/coldstart.py                        # cold start × warm start × SnapStart
python analysis/calibration.py                      # piloto: onde cada braço satura
BILLING_CAMPAIGN_DAYS=2026-08-28,2026-08-29 python analysis/cost-model.py
```

O `analyze.py` e o `cost-model.py` aceitam os diretórios de entrada e saída como argumentos
(`python analysis/analyze.py <results/> <saida/>`). Detalhes em
[load-tests/README.md](load-tests/README.md) e [analysis/README.md](analysis/README.md).

## Provisionamento na AWS

A infraestrutura das três arquiteturas (recursos, pré-requisitos, ordem de aplicação,
custos e _teardown_) está em [infra/terraform/](infra/terraform/) — ver o seu README.
**O AWS Budget é sempre o primeiro recurso**, e a infraestrutura deve ser derrubada
(`terraform destroy`) após cada janela de medição.

### Rodar o experimento de ponta a ponta

[run-aws-experiment.ps1](run-aws-experiment.ps1) orquestra o ciclo completo **uma
arquitetura por vez**: `terraform apply` (só daquele braço) → espera o app responder →
bateria k6 → captura de métricas (CloudWatch / cold start) → **`terraform destroy`**.
O teardown roda no `finally` — derruba a infra mesmo se o k6 falhar ou travar (há um
_watchdog_ de tempo).

```powershell
.\run-aws-experiment.ps1 -Quick            # ensaio: sobe, roda pouco, captura e DESTRÓI
.\run-aws-experiment.ps1 -Calibrate        # piloto: localiza a saturação de cada braço
.\run-aws-experiment.ps1 -Only mono,micro  # rodada real de braços específicos
.\run-aws-experiment.ps1                   # tudo, 10 repetições por cenário
```

Requer `aws configure` feito, `infra/terraform/terraform.tfvars` preenchido e o **Budget**
já aplicado. Não cobre queda de energia / suspensão do computador — antes de rodar sem
supervisão: `powercfg /change standby-timeout-ac 0`.

O custo faturado é capturado depois, com [analysis/billing-capture.ps1](analysis/billing-capture.ps1)
(o Cost Explorer leva cerca de 24 h para consolidar).

## Métricas coletadas

- **Desempenho:** tempo de resposta (média, mediana, p95 e p99), throughput e taxa de erro
- **Vazão útil:** desconta as respostas agregadas devolvidas sem conteúdo
- **Recursos:** CPU e memória por contêiner via CloudWatch, em valores absolutos (vCPU e GB),
  distinguindo aplicação, serviços de plataforma e proxy do Service Connect
- **Serverless:** cold start × warm start e duração faturada, nos dois subcenários
- **Custo:** modelo analítico por perfil de tráfego, validado contra a fatura da plataforma

As comparações usam a **repetição** como unidade amostral, com Kruskal-Wallis seguido de
Mann-Whitney com correção de Bonferroni e Cliff's delta para magnitude.

## Licença

Distribuído sob a **Apache License 2.0** — ver [LICENSE](LICENSE) e [NOTICE](NOTICE).
Baseia-se no [Spring PetClinic](https://github.com/spring-petclinic), também Apache-2.0.
