variable "region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Prefixo de nomes dos recursos"
  type        = string
  default     = "tcc-petclinic"
}

variable "budget_amount" {
  description = "Teto mensal do budget (USD)"
  type        = number
  default     = 20
}

variable "alert_thresholds_pct" {
  description = "Limiares de alerta (% do teto). 25/50/100 de US$20 = US$5/10/20."
  type        = list(number)
  default     = [25, 50, 100]
}

variable "alert_emails" {
  description = "E-mails que recebem os alertas de budget"
  type        = list(string)
}
