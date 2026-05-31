# Fase 7 — Provisionamento na AWS (planejamento)

Plano de infraestrutura para subir as **três arquiteturas** na AWS, medir com k6 e
**derrubar**. IaC em **Terraform**.

> 🔴 **Regras de custo do projeto:** o **AWS Budget é o PRIMEIRO recurso**; nada de
> NAT Gateway; janelas curtas; **`terraform destroy` ao fim de cada sessão de
> medição**; conta e cartão criados manualmente pelos autores.

---

## 1. Decisões de arquitetura na AWS

| Arquitetura | Serviço | Detalhe |
|---|---|---|
| Monolito | **EC2** (1 instância) | `java -jar` do fat jar; instância de computação contínua |
| Microsserviços | **ECS Fargate** | 1 *service* Fargate por microsserviço; descoberta via **ECS Service Connect**; **ALB** expõe o gateway |
| Serverless | **Lambda + API Gateway** | 6 funções × **2 subcenários** (sem otimização × **SnapStart**); jar no S3 |
| Banco | **MySQL em contêiner numa EC2** | compartilhado pelas 3 (decisão 3); sem RDS |

### Rede — SEM NAT (vilão de custo)
- Uma **VPC** com **subnets públicas** + **Internet Gateway** (grátis; NAT seria pago).
- EC2 (monolito, MySQL) e tarefas Fargate em subnet pública com IP público → acessam
  Docker Hub / internet pelo IGW, sem NAT.
- **Lambda em VPC** (mesma VPC) só para alcançar o MySQL; como a função não precisa de
  internet (dependências no jar, sem chamadas externas), **não precisa de NAT**.
- **Security Groups** restringem tudo:
  - `sg-mysql`: porta 3306 **apenas** dos SGs das apps (mono, micro, lambda);
  - `sg-mono`: 9966 e 22 apenas do **IP do autor** (gerador k6/SSH);
  - `sg-alb`: 8080/80 apenas do IP do autor;
  - API Gateway é público (endpoint HTTPS), sem porta a abrir.

### Equivalência de recursos (decisão 3.4 / Quadro 2)
Dimensionar para capacidade comparável e registrar no Quadro 2:
- Monolito: **EC2 t3.small** (2 vCPU burst, 2 GB) — ponto de partida.
- Fargate: 6 tarefas × **0,25 vCPU / 0,5 GB** (~1,5 vCPU / 3 GB no total) ≈ comparável.
- Lambda: **2048 MB** (mais memória = mais CPU → cold start menor). Calibrar e anotar.

### Serverless — dois subcenários (decisão 2)
- (a) **Sem otimização**: funções Lambda Java padrão (cold start puro).
- (b) **SnapStart**: `snap_start { apply_on = "PublishedVersions" }` nas mesmas funções
  (compatível: zip/uber-jar + runtime gerenciado java17). Exige versão publicada + alias.
- Cada subcenário tem seu próprio conjunto de funções/rotas → duas URLs de API Gateway
  (`serverless-cold` e `serverless-snap` no k6/análise).

---

## 2. IaC — Terraform

**Por que Terraform e não SAM:** o SAM já serve à validação local (`sam local`); na AWS,
o Terraform cobre **as três arquiteturas com uma só ferramenta** (EC2 + ECS + Lambda +
API Gateway + Budget + rede). O `aws_lambda_function` suporta `snap_start`, então o
braço serverless inteiro (2 subcenários) fica em Terraform.

### Estrutura proposta
```
infra/terraform/
├── 00-budget/              # APLICAR PRIMEIRO, isolado (antes de qualquer outro recurso)
│   ├── main.tf             # aws_budgets_budget + notificação por e-mail
│   └── variables.tf
├── providers.tf            # provider aws (region us-east-1), versão
├── variables.tf            # region, my_ip, instance types, key_name, db creds, emails
├── terraform.tfvars        # valores (gitignored — contém IP/segredos)
├── network.tf              # VPC/subnets (ou data da default VPC) + Security Groups
├── mysql.tf                # EC2 do MySQL + user-data (docker mysql:8.4 + seed)
├── monolith.tf             # EC2 do monolito + user-data (java -jar)
├── microservices.tf        # ECS cluster, task defs, services, Service Connect, ALB
├── serverless.tf           # S3 (jar), IAM role, 6+6 Lambdas, API Gateway, SnapStart
├── outputs.tf              # URLs: mono, ALB micro, API GW cold/snap
└── scripts/
    ├── mysql-userdata.sh   # sobe MySQL + carrega schema/data.sql
    └── monolith-userdata.sh# instala Java + roda o jar
```

`00-budget/` é um *root module* separado, aplicado **antes** do resto, para garantir a
ordem "budget primeiro".

### Estado do Terraform
- **Local** (`terraform.tfstate`) — suficiente para um TCC. **Gitignorar** (contém dados
  sensíveis). Sem backend remoto (S3/DynamoDB) para não criar recursos extras.

---

## 3. Recursos AWS por braço

| Braço | Recursos Terraform |
|---|---|
| Comum | VPC/subnets (ou default), IGW, 3–4 Security Groups, par de chaves EC2 |
| Budget | `aws_budgets_budget` (mensal, alertas 50/80/100% → e-mail) |
| MySQL | `aws_instance` (t3.small) + user-data (docker mysql:8.4 + seed) |
| Monolito | `aws_instance` (t3.small) + user-data (java -jar, env MYSQL_URL) |
| Microsserviços | `aws_ecs_cluster`, `aws_ecs_task_definition` (×6), `aws_ecs_service` (×6, Service Connect), `aws_lb` + `aws_lb_target_group`/`listener` (ALB → gateway) |
| Serverless | `aws_s3_bucket` + `aws_s3_object` (uber-jar), `aws_iam_role` (exec + VPC), `aws_lambda_function` (×6 sem-otim + ×6 SnapStart), `aws_lambda_alias`, `aws_apigatewayv2_api`/rotas/integrações (×2) |

> Imagens dos microsserviços: usar as públicas `springcommunity/spring-petclinic-*`
> (Fargate puxa direto do Docker Hub) — **não precisa** build/push para ECR.

---

## 4. Credenciais e pré-requisitos (você cria manualmente)

1. **Usuário IAM** com acesso programático (Access Key + Secret). Para um TCC, o mais
   simples é **AdministratorAccess** numa conta dedicada/descartável; alternativa: política
   restrita a EC2, ECS, Lambda, API Gateway, IAM (PassRole), S3, Budgets, VPC, ELB,
   CloudWatch Logs.
   ```powershell
   aws configure   # cola Access Key/Secret; region us-east-1; output json
   aws sts get-caller-identity   # confirma
   ```
2. **Par de chaves EC2** (para SSH no monolito/MySQL): criar no console ou via Terraform
   (`aws_key_pair` com sua chave pública).
3. **Terraform CLI** instalado (`winget install Hashicorp.Terraform`).
4. **Seu IP público** (para os Security Groups): `curl ifconfig.me`.
5. Conta AWS + cartão (já criados manualmente).

---

## 5. Estimativa de custo (disciplinado: janelas curtas + destroy)

| Item | Custo aprox. | Observação |
|---|---|---|
| EC2 t3.small × 2 (mono + mysql) | ~US$ 0,021/h cada | ~US$ 0,42 em 10 h de uso |
| Fargate (6 × 0,25vCPU/0,5GB) | ~US$ 0,074/h | ~US$ 0,74 em 10 h |
| ALB | ~US$ 0,0225/h + LCU | ~US$ 0,25 em 10 h |
| Lambda (invocações + GB-s) | poucos US$ | free tier cobre boa parte; **INIT tarifado** (ago/2025) |
| S3 (jar ~172 MB) | centavos | |
| EBS / transferência | centavos | volumes pequenos, deletar no destroy |
| **Total estimado** | **< US$ 5** se as janelas forem curtas | teto do Budget em US$ 20 dá folga |

---

## 6. Passo a passo (runbook da Fase 7)

1. **Budget primeiro:** `cd infra/terraform/00-budget && terraform init && terraform apply`.
   Confirmar o alerta de e-mail antes de prosseguir.
2. **Artefatos:** monolito `…-exec.jar`; serverless `…-aws.jar` (Terraform sobe no S3);
   microsserviços usam imagens públicas (nada a buildar).
3. **Provisionar (ordem):** `cd infra/terraform && terraform init && terraform apply`
   - primeiro o **MySQL** (user-data sobe + semeia), depois mono, micro e serverless.
   - usar `-target` se quiser subir um braço por vez (economiza tempo ligado).
4. **Outputs:** `terraform output` → URL do monolito, do ALB (micro), e as 2 do API Gateway.
5. **k6 (da máquina local):**
   ```powershell
   .\load-tests\run-all.ps1 -Target mono       -BaseUrl http://<ec2-mono>:9966/petclinic/api -Reps 7
   .\load-tests\run-all.ps1 -Target micro      -BaseUrl http://<alb-dns>:8080/api            -Reps 7
   .\load-tests\run-all.ps1 -Target serverless -BaseUrl <api-gw-cold>/api  -Label serverless-cold -Reps 7
   .\load-tests\run-all.ps1 -Target serverless -BaseUrl <api-gw-snap>/api  -Label serverless-snap -Reps 7
   ```
   (Registrar a latência de base — o `run-all` já faz.)
6. **Cold start (ver §7):** induzir cold starts + extrair `Init Duration` do CloudWatch,
   nos dois subcenários → `results/coldstart/measurements.csv`.
7. **Análise:** `python analysis/analyze.py` + `python analysis/coldstart.py`.
8. **DESTRUIR:** `terraform destroy` nos dois módulos; conferir no console que nada ficou;
   olhar o Billing.

## 7. Captura de cold start × warm start (CloudWatch)

- **Induzir cold start:** forçar novo ambiente entre invocações (ex.: atualizar uma
  variável de ambiente trivial da função, ou publicar nova versão), invocar 1× e medir.
- **Warm:** invocar repetidamente o mesmo ambiente.
- **Extrair:** a linha `REPORT` do CloudWatch Logs traz `Duration` e `Init Duration`
  (este só no cold). Script `coldstart-capture.ps1` (a escrever) com:
  ```powershell
  aws logs filter-log-events --log-group-name /aws/lambda/<fn> --filter-pattern "REPORT"
  ```
  → normalizar para `subscenario,invocation,init_ms,duration_ms` e alimentar o `coldstart.py`.
- Repetir para **sem-otim** e **SnapStart**.

## 8. Checklist de teardown (OBRIGATÓRIO ao fim de cada sessão)

```powershell
cd infra/terraform        ; terraform destroy
cd infra/terraform/00-budget ; terraform destroy   # (ou manter o budget)
# conferir que nada sobrou:
aws ec2 describe-instances  --filters "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId"
aws ecs list-services       --cluster <cluster>
aws lambda list-functions   --query "Functions[].FunctionName"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
```
- Apagar **Elastic IP** ocioso e **EBS** órfão (cobram parados).
- Conferir o **Billing** do dia.

## 9. Quadro 2 (a preencher com os valores reais da Fase 7)
Região, tipo/dimensionamento da EC2, config da tarefa Fargate, memória do Lambda,
runtime Java (17), SGBD (MySQL 8.4), commits (mono `4020fdb`; micro `305a1f1`; serverless
= base do monolito + `spring-petclinic-serverless`), versão do spring-cloud-function (5.0.x).
