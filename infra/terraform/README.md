# Terraform — infraestrutura AWS (PetClinic)

IaC das três arquiteturas (EC2 monolito · ECS Fargate microsserviços · Lambda + API
Gateway serverless), MySQL compartilhado e AWS Budget.

> 🔴 **`terraform apply` sempre com o Budget primeiro**, em janelas curtas, com
> `terraform destroy` ao fim de cada medição (controle de custo). Estimativa
> **< US$ 5** com disciplina (teto do Budget em US$ 20).

## Escolhas (aprovadas)
- Microsserviços: **ECS Fargate + Service Connect** (serviços independentes).
- IAM: usuário **AdministratorAccess + MFA** (conta dedicada).
- Lambda: **em VPC** alcançando o MySQL (sem NAT).
- Estado: **local** (`.tfstate` gitignorado — necessário para o `destroy`, não perca).

## Pré-requisitos (passos manuais na AWS)
1. Usuário IAM **AdministratorAccess + MFA**; `aws configure` (Access Key/Secret; region us-east-1).
2. **Habilitar acesso ao Billing** — como root: *Account → IAM user and role access to
   Billing information → Activate*. **Sem isso o módulo `00-budget` falha.**
3. Par de chaves EC2 criado no console → nome em `key_name`.
4. Seu IP: `curl ifconfig.me` → `my_ip_cidr = "x.x.x.x/32"`.
5. Artefatos buildados localmente (o Terraform sobe no S3):
   - monolito: `cd apps/monolith && .\mvnw.cmd -DskipTests package` (gera `-exec.jar`)
   - serverless: `cd serverless && .\mvnw.cmd -DskipTests package` (gera `-aws.jar`)
6. `terraform.tfvars` (copiar do `.example`) — nos **dois** módulos (`00-budget/` e a raiz).

## Ordem de aplicação
```powershell
# 1) BUDGET PRIMEIRO (módulo isolado)
cd infra\terraform\00-budget
terraform init ; terraform apply        # confirmar o e-mail de alerta

# 2) Resto da infra
cd ..
terraform init ; terraform apply
terraform output                         # URLs para o k6 (output k6_commands)
```

## Estrutura
| Arquivo | Conteúdo |
|---|---|
| `00-budget/` | AWS Budget + alertas (aplicar 1º) |
| `providers.tf` `variables.tf` `data.tf` | base |
| `network.tf` | VPC, subnets públicas, IGW, Security Groups (sem NAT) |
| `iam.tf` `artifacts.tf` | papel das EC2 + bucket S3 (jars, schema/data) |
| `mysql.tf` `monolith.tf` `scripts/` | EC2 do MySQL e do monolito (user-data) |
| `microservices.tf` | ECS Fargate + Service Connect + ALB (6 serviços) |
| `serverless.tf` | 12 Lambdas (6×2 subcenários), API Gateway, SnapStart |
| `outputs.tf` | URLs base do k6 |

## Teardown (ao fim de cada sessão)
```powershell
cd infra\terraform ; terraform destroy
# (o budget pode ficar) ; conferir no console que nada sobrou; olhar o Billing
```

## Avisos (validar no `terraform plan/apply`)
- **Microsserviços** é o braço mais sensível: ordem de subida (config/discovery
  primeiro — os apps fazem retry, então sobe eventualmente), Service Connect e o
  health check do gateway podem pedir ajuste fino.
- **Serverless**: API Gateway HTTP com `payload_format_version = "1.0"` (casa com
  `APIGatewayProxyRequestEvent`); SnapStart via alias/versão publicada.
- O uber-jar (~172 MB) sobe via S3 (acima do limite de upload direto do Lambda).
