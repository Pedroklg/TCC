variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  type    = string
  default = "tcc-petclinic"
}

variable "admin_ip_cidr" {
  description = "IP do operador em CIDR — libera SSH no runner. curl -4 ifconfig.me (sem VPN)"
  type        = string
}

variable "key_name" {
  description = "Par de chaves EC2 já existente; o mesmo do experimento, porque o runner também abre SSH no MySQL"
  type        = string
}

variable "instance_type" {
  description = "4 vCPU sustentam o pico de ~750 req/s com folga, o que preserva a afirmação de §3.4 de que o cliente não limitou"
  type        = string
  default     = "c5.xlarge"
}

variable "volume_gb" {
  description = "A campanha definitiva grava cerca de 30 GB de JSON bruto do k6"
  type        = number
  default     = 100
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}
