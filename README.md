# PetClinic — Comparação de Arquiteturas (Monolito × Microsserviços × Serverless)

Artefatos de um **Trabalho de Conclusão de Curso (TCC)** de Engenharia de Software
que compara empiricamente **desempenho, escalabilidade e complexidade operacional**
de três estilos arquiteturais, usando o benchmark **Spring PetClinic** sob testes de
carga com **Grafana k6**.

> Este repositório contém **scripts de carga, a versão serverless, ferramentas de
> análise e a infraestrutura (IaC)**. Vários comentários no código referenciam
> decisões e seções da metodologia do TCC — propositalmente, para ligar o código ao
> texto. As três arquiteturas usam o **mesmo domínio** (PetClinic) e o **mesmo SGBD**
> (MySQL), de modo que as diferenças observadas decorram do estilo arquitetural.

## As três arquiteturas

| Arquitetura | Implementação | Plataforma AWS (Terraform) |
|---|---|---|
| **Monolito** | `spring-petclinic-rest` oficial (JAR único) | EC2 |
| **Microsserviços** | `spring-petclinic-microservices` oficial (serviços decompostos) | ECS Fargate + Service Connect |
| **Serverless (FaaS)** | domínio refatorado em funções via **spring-cloud-function** (ver [serverless/](serverless/)) | Lambda + API Gateway (2 subcenários: cold start × SnapStart) |

Stack: Java 17, Spring Boot 4.0.6, MySQL 8.4. Serverless: spring-cloud-function 5.0.x.

## Estrutura do repositório

```
.
├── serverless/        # app FaaS (spring-cloud-function) — reúsa o domínio do monolito
├── load-tests/        # cenários k6 (constante, rampa, pico) + workload + runner
├── analysis/          # análise das métricas (Python) + cold start
└── infra/
    ├── docker-compose.mysql.yml            # MySQL compartilhado (local)
    ├── docker-compose.microservices.yml    # stack de microsserviços (local)
    ├── reset-db.ps1                         # reset do banco ao baseline entre repetições
    └── terraform/                           # IaC da AWS (EC2, ECS, Lambda, API GW, Budget) + README
```

> Os repositórios **oficiais** do PetClinic (monolito e microsserviços) **não** são
> versionados aqui — são clonados em `apps/` (ver abaixo).

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
.\load-tests\run-all.ps1 -Target mono  -Reps 7 -ResetBetweenReps
.\load-tests\run-all.ps1 -Target micro -Reps 7 -ResetBetweenReps

# análise (gera tabelas e gráficos comparativos + cold start)
python analysis/analyze.py
python analysis/coldstart.py
```
Detalhes em [load-tests/README.md](load-tests/README.md) e [analysis/README.md](analysis/README.md).

## Provisionamento na AWS
A infraestrutura das três arquiteturas (recursos, pré-requisitos, ordem de aplicação,
custos e *teardown*) está em [infra/terraform/](infra/terraform/) — ver o seu README.
**O AWS Budget é sempre o primeiro recurso**, e a infraestrutura deve ser derrubada
(`terraform destroy`) após cada janela de medição.

## Métricas coletadas
Tempo de resposta (média, p95, p99), throughput (req/s) e taxa de erro (%). Para a
serverless, também tempo de inicialização **cold start × warm start** nos dois
subcenários (sem otimização × SnapStart).
