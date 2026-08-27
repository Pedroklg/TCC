output "runner_public_ip" {
  value = aws_eip.runner.public_ip
}

# Vai para my_ip_cidr em infra/terraform/terraform.tfvars: sem isso os Security
# Groups do experimento bloqueiam o k6 e o SSH do reset-db vindos do runner.
output "runner_ip_cidr" {
  value = "${aws_eip.runner.public_ip}/32"
}

output "ssh_command" {
  value = "ssh -i <chave.pem> ubuntu@${aws_eip.runner.public_ip}"
}

# Identifica a imagem da campanha (Quadro 2).
output "runner_ami_id" {
  value = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
}
