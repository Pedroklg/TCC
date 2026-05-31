# =============================================================================
# 00-budget — PRIMEIRO recurso a ser criado na AWS (regra de ouro do TCC).
# Aplicar ISOLADAMENTE antes de qualquer outro módulo:
#   cd infra/terraform/00-budget && terraform init && terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

# Budget mensal de custo com alertas por e-mail (real + previsto).
resource "aws_budgets_budget" "tcc" {
  name         = "${var.prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alertas por gasto REAL nos limiares (ex.: 25/50/100% de US$20 = US$5/10/20).
  dynamic "notification" {
    for_each = var.alert_thresholds_pct
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.alert_emails
    }
  }

  # Alerta também por PREVISÃO de estouro (antecipa antes de gastar).
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_emails
  }
}
