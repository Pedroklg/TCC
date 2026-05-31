# --- Gerais ---
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "tcc-petclinic"
}

variable "my_ip_cidr" {
  description = "Seu IP público em CIDR (ex.: 203.0.113.5/32) — libera SSH/k6 só para você. curl ifconfig.me"
  type        = string
}

variable "key_name" {
  description = "Nome do par de chaves EC2 já existente (para SSH no monolito/MySQL)"
  type        = string
}

# --- Rede ---
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"] # 2 AZs (ALB/Fargate exigem 2)
}

# --- Banco (decisão 3: MySQL em contêiner, config idêntica entre as 3) ---
variable "db_name" {
  type    = string
  default = "petclinic"
}
variable "db_user" {
  type    = string
  default = "petclinic"
}
variable "db_password" {
  type      = string
  default   = "petclinic"
  sensitive = true
}

# --- Dimensionamento (equivalência de recursos — Quadro 2) ---
variable "mysql_instance_type" {
  type    = string
  default = "t3.small"
}
variable "monolith_instance_type" {
  type    = string
  default = "t3.small"
}
variable "fargate_cpu" {
  type    = number
  default = 256 # 0,25 vCPU por serviço
}
variable "fargate_memory" {
  type    = number
  default = 512 # 0,5 GB por serviço
}
variable "lambda_memory_mb" {
  type    = number
  default = 2048
}

# --- Artefatos locais (Terraform sobe no S3) ---
variable "monolith_jar_path" {
  description = "Caminho local do fat jar executável do monolito (-exec.jar)"
  type        = string
  default     = "../../apps/monolith/target/spring-petclinic-rest-4.0.2-exec.jar"
}
variable "serverless_jar_path" {
  description = "Caminho local do uber-jar do serverless (-aws.jar)"
  type        = string
  default     = "../../serverless/target/spring-petclinic-serverless-1.0.0-aws.jar"
}

# --- Microsserviços (imagens públicas oficiais) ---
variable "micro_image_tag" {
  type    = string
  default = "latest"
}
variable "config_git_uri" {
  description = "Repo git de configuração do spring-petclinic-microservices"
  type        = string
  default     = "https://github.com/spring-petclinic/spring-petclinic-microservices-config"
}
