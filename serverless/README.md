# Serverless (FaaS) — PetClinic em funções (spring-cloud-function)

Versão **serverless de verdade**: o domínio do PetClinic é refatorado em **funções de
responsabilidade única** com [spring-cloud-function](https://spring.io/projects/spring-cloud-function),
implantadas individualmente como **AWS Lambda** atrás de um **API Gateway**.
Segue a abordagem do projeto de referência `foyst/spring-petclinic-rest-serverless`
(FOSTER, 2021), porém **reconstruída sobre a mesma base de domínio e as mesmas versões
do monolito** (Opção A) — eliminando o confound de versões de bibliotecas.

> NÃO é o monolito embrulhado (a abordagem AWS Lambda Web Adapter foi descartada).

## Estrutura

```
serverless/
├── pom.xml                  # Boot 4.0.6, scf 5.0.x (Spring Cloud 2025.1.1), shade p/ Lambda
├── template.yaml            # SAM: 6 funções -> rotas do API Gateway
├── src/main/java/.../serverless/
│   ├── ServerlessApplication.java   # reúsa service+mapper+model+repository do monolito
│   └── LambdaConfig.java            # as 6 funções (Function<APIGatewayProxyRequestEvent,...>)
├── src/main/resources/application.properties   # web=none, perfil spring-data-jpa, MySQL
└── src/test/java/.../WiringTest.java           # valida contexto+JPA+funções
```

## Funções (reusam `ClinicService` + mappers → JSON idêntico ao monolito)

| Função | Rota (API Gateway) | Operação |
|---|---|---|
| `getAllOwners` | `GET /api/owners` | lista owners |
| `getOwnerById` | `GET /api/owners/{ownerId}` | ficha (owner+pets+visits) |
| `listVets` | `GET /api/vets` | lista vets |
| `listPetTypes` | `GET /api/pettypes` | lista tipos |
| `createOwner` | `POST /api/owners` | cadastra owner |
| `createVisit` | `POST /api/owners/{ownerId}/pets/{petId}/visits` | agenda visita |

## Pré-requisitos

1. **Monolito instalado como biblioteca** (fornece o domínio):
   ```powershell
   cd apps\monolith ; .\mvnw.cmd -DskipTests install   # gera spring-petclinic-rest-4.0.2.jar no .m2
   ```
2. Java 17, Docker (para `sam local`), AWS SAM CLI.

## Build

```powershell
cd serverless
.\mvnw.cmd -DskipTests package   # gera target/spring-petclinic-serverless-1.0.0-aws.jar (uber-jar do Lambda)
```

## Validação local (sem AWS, sem custo)

**1. Wiring + domínio (rápido)** — requer o MySQL compartilhado de pé e semeado:
```powershell
docker compose -f ..\infra\docker-compose.mysql.yml up -d
.\mvnw.cmd test    # WiringTest: contexto sobe sem a camada web, JPA conecta, 6 funções OK
```

**2. Via HTTP (sam local)** — valida o caminho API Gateway→Lambda→função→MySQL:
```powershell
sam local start-api --warm-containers LAZY
# noutro terminal (a 1a chamada é lenta — cold start):
curl http://127.0.0.1:3000/api/owners
```

> ⚠️ **Cold start na emulação do SAM é lentíssimo (~150–200 s no Windows)**; é
> artefato da emulação. No Lambda real fica na casa de ~10–15 s. Chamada **quente
> ~1,3 s**. Por isso o `sam local` serve para validação **funcional** (curl), não
> para carga k6 — o k6 de serverless roda na **AWS** (Fase 7).

## Notas técnicas (Spring Boot 4 é recente — armadilhas tratadas)

- **Jackson 3**: namespace `tools.jackson` (não `com.fasterxml.jackson`); exceções *unchecked*.
- **`@EntityScan`** mudou para `org.springframework.boot.persistence.autoconfigure`.
- **`FunctionInvoker`** precisa da env **`MAIN_CLASS`** (o uber-jar achatado não tem `Start-Class` no manifesto).
- **Empacotamento**: só `maven-shade-plugin` (sem o repackage do `spring-boot-maven-plugin`,
  que aninharia as classes em `BOOT-INF/` e quebraria o shade). Handler:
  `org.springframework.cloud.function.adapter.aws.FunctionInvoker`. Função selecionada por
  `SPRING_CLOUD_FUNCTION_DEFINITION`.

## Cold start × warm start (objeto de estudo)

O contraste cold (~150–200 s emulação / ~10–15 s no Lambda) × warm (~1,3 s) é
exatamente o fenômeno avaliado. Na AWS (Fase 7) a serverless é medida em **dois
subcenários**: (a) sem otimização e (b) com **SnapStart** (compatível: zip + runtime
gerenciado java17).

## Deploy na AWS — só na Fase 7 (após o Budget)

- O uber-jar (~172 MB) excede o limite de upload direto do Lambda → vai por **S3**
  (`sam deploy` resolve com `--resolve-s3`).
- Apontar `MYSQL_URL` para o MySQL compartilhado; conferir a versão do runtime.
- Habilitar SnapStart na função do subcenário (b).
