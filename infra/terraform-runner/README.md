# terraform-runner — gerador de carga na AWS

Sobe uma EC2 em `us-east-1` que executa a campanha inteira (`run-aws-experiment.ps1`)
sem depender do notebook do operador.

**Por que existe.** Com o gerador em Ponta Grossa o RTT até `us-east-1` fica em 120 a
160 ms, e como cada iteração faz de 2 a 4 requisições sequenciais, boa parte da latência
medida é propagação. A constante incide igualmente nos três braços, mas comprime o
tamanho de efeito e injeta jitter residencial no p95 e no p99. Na mesma região o RTT cai
para 1 a 2 ms. Some-se a isso que `my_ip_cidr` é um `/32` único: se o IP residencial
renegociar no meio de uma campanha de 12 horas, os Security Groups passam a bloquear o k6
e a rodada é perdida.

**Por que num state próprio.** O orquestrador roda `terraform destroy` ao fim de cada
braço. Como o runner está em outro diretório e outro state, o destroy não o alcança.

O custo do runner é aparato experimental e **não entra** na comparação de custo entre
arquiteturas (§3.6). A tag `Project` dele é `tcc-petclinic-runner`, distinta da do
experimento, o que separa o gasto no Cost Explorer e evita falso alarme no
`Confirm-Teardown`.

---

## 1. Pré-requisitos

- Par de chaves EC2 `tcc-keypair` já criado, com o `.pem` em mãos.
- Módulo `00-budget` já aplicado.
- JARs já construídos localmente (`apps/monolith/target/` e `serverless/target/`).

## 2. Subir o runner

```bash
cd infra/terraform-runner
cp terraform.tfvars.example terraform.tfvars    # preencha admin_ip_cidr
terraform init
terraform apply
```

`admin_ip_cidr` é o **seu** IP, e libera só o SSH no runner. Confira sem VPN:

```bash
curl -4 ifconfig.me
```

## 3. Apontar o experimento para o runner

```bash
terraform -chdir=infra/terraform-runner output -raw runner_ip_cidr
```

Esse valor vai em `my_ip_cidr` de `infra/terraform/terraform.tfvars`. Os Security Groups
do experimento liberam k6 e SSH só para ele, então **a partir daqui o notebook deixa de
alcançar os alvos**. Para manter os dois acessos seria preciso transformar `my_ip_cidr`
em lista.

## 4. Levar a árvore e o que ela não versiona

A campanha precisa rodar **o mesmo commit** validado no notebook. Um `git clone` traz o
branch padrão do GitHub, que pode estar atrás do que se vai executar, e a diferença só
apareceria como dado degradado horas depois. `git archive` empacota o `HEAD` local e
elimina esse risco.

Fora da árvore versionada ficam `apps/`, `terraform.tfvars` e os states, ignorados por
design. Ao todo são cerca de 160 MB:

```bash
IP=$(terraform -chdir=infra/terraform-runner output -raw runner_public_ip)

git archive --format=tar --prefix=TCC/ HEAD | gzip > /tmp/tcc-tree.tgz

tar -czf /tmp/runner-payload.tgz \
  apps/monolith/target/spring-petclinic-rest-4.0.2-exec.jar \
  apps/monolith/src/main/resources/db/mysql/schema.sql \
  apps/monolith/src/main/resources/db/mysql/data.sql \
  serverless/target/spring-petclinic-serverless-1.0.0-aws.jar \
  infra/terraform/terraform.tfvars \
  infra/terraform/00-budget/terraform.tfstate

scp -i tcc-keypair.pem /tmp/tcc-tree.tgz /tmp/runner-payload.tgz tcc-keypair.pem ubuntu@$IP:~/
```

O state do `00-budget` precisa ir junto: sem ele o preflight acusa o budget como não
aplicado, e um `apply` às cegas tentaria criar um budget duplicado.

## 5. Preparar a máquina

```bash
ssh -i tcc-keypair.pem ubuntu@$IP

cat /etc/tcc-runner-ready          # só existe quando o provisionamento terminou
chmod 600 ~/tcc-keypair.pem

tar -xzf ~/tcc-tree.tgz
cd TCC
tar -xzf ~/runner-payload.tgz

python3 -m venv ~/venv
~/venv/bin/pip install -r analysis/requirements.txt
```

## 6. Rodar a campanha

Sob `tmux`, para a sessão sobreviver à queda do SSH:

```bash
tmux new -s tcc
cd ~/TCC
pwsh ./run-aws-experiment.ps1 -DbSshKey ~/tcc-keypair.pem
```

`Ctrl+B` seguido de `D` desanexa; `tmux attach -t tcc` volta. Ensaie antes com `-Quick`.

## 7. Resgatar os resultados

A campanha grava cerca de 30 GB de JSON bruto. Rode a análise **na própria máquina** e
baixe só as saídas.

```bash
~/venv/bin/python analysis/analyze.py
~/venv/bin/python analysis/cost-model.py
~/venv/bin/python analysis/coldstart.py

BUCKET=tcc-petclinic-results-$(aws sts get-caller-identity --query Account --output text)
aws s3 mb s3://$BUCKET

aws s3 sync analysis/figures   s3://$BUCKET/figures
aws s3 sync analysis/tables    s3://$BUCKET/tables
aws s3 sync results/resources  s3://$BUCKET/resources
aws s3 sync results/coldstart  s3://$BUCKET/coldstart

# summaries + covariáveis por repetição (poucos MB)
find results \( -name '*-summary.json' -o -name 'baseline-latency.csv' \
  -o -name 'client-cpu.csv' -o -name 'run-metadata.json' \) | tar -czf - -T - \
  | aws s3 cp - s3://$BUCKET/summaries.tgz

# JSON bruto comprimido, para poder reprocessar depois (o piloto comprimiu 33x)
tar -czf - results | aws s3 cp - s3://$BUCKET/raw.tgz
```

O bucket fica **fora** do Terraform de propósito: os resultados têm ciclo de vida
diferente do da máquina e não podem ser levados por um `destroy`.

No notebook:

```bash
aws s3 sync s3://$BUCKET ./results-aws --exclude 'raw.tgz'
```

## 8. Destruir

Só depois de confirmar que o sync terminou: o EBS do runner vai junto.

```bash
terraform -chdir=infra/terraform-runner destroy
```

Confira antes que o experimento já foi destruído pelo orquestrador:

```bash
terraform -chdir=infra/terraform state list      # deve sair vazio
```

## 9. Custo

| Item | Cálculo | USD |
|---|---|---|
| c5.xlarge, 14 h | 14 × 0,17 | 2,38 |
| EBS gp3 100 GB, 3 dias | 100 × 0,08 × 3/30 | 0,80 |
| IPv4 público, 14 h | 14 × 0,005 | 0,07 |
| Transferência na região (~16 GB, ida e volta) | ~0,02/GB | 0,32 |
| S3 (~3 GB por um mês) | | 0,07 |
| **Total** | | **~3,64** |

Preços de `us-east-1` consultados em ago. 2026; reconferir na data da execução.
Enquanto a campanha não roda, `terraform destroy` zera tudo menos o bucket.
