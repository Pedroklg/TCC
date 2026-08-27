# =============================================================================
# terraform-runner — gerador de carga em EC2, com state PRÓPRIO.
#
# Fica fora do state de infra/terraform: o `terraform destroy` que o orquestrador
# roda ao fim de cada braço não alcança esta máquina, então ela conduz a campanha
# inteira sem depender do notebook do operador.
#
# Como usar: ver README.md desta pasta.
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
  default_tags {
    tags = {
      # Tag distinta da do experimento: Confirm-Teardown acusa EC2 viva com
      # Project=<prefix>, e o runner é justamente a que deve continuar de pé.
      # Separa também o custo do aparato do custo das arquiteturas (§3.6).
      Project   = "${var.prefix}-runner"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# VPC default: os alvos são alcançados por endereço público de qualquer forma
# (API Gateway e ALB são endpoints públicos), então estar na VPC do experimento
# não traria tráfego privado e ainda exporia o runner ao destroy.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  # AZ fixa: us-east-1e não oferece parte das famílias c5.
  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "runner" {
  name        = "${var.prefix}-runner"
  description = "Gerador de carga: SSH apenas do IP do operador"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-runner" }
}

# ============================ Permissões ============================
# Perfil de instância no lugar de chave de acesso de longa duração no disco.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.prefix}-runner"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "runner" {
  # Serviços que o Terraform do experimento e os scripts de captura manipulam.
  statement {
    sid = "ExperimentServices"
    actions = [
      "ec2:*", "ecs:*", "elasticloadbalancing:*", "lambda:*",
      "apigateway:*", "s3:*", "logs:*", "cloudwatch:*",
      "servicediscovery:*", "budgets:*", "application-autoscaling:*",
      "sts:GetCallerIdentity", "ssm:GetParameter", "ssm:GetParameters",
    ]
    resources = ["*"]
  }

  # Escrita em IAM só nos nomes do projeto: o experimento cria roles, políticas e
  # instance profiles com o prefixo, e nada fora dele.
  statement {
    sid     = "ProjectIamWrite"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.prefix}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.prefix}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.prefix}-*",
    ]
  }

  # Leitura ampla em IAM para o Terraform resolver políticas gerenciadas, mais a
  # service-linked role do ECS, que o preflight cria em conta nova.
  statement {
    sid       = "IamReadAndEcsServiceLinkedRole"
    actions   = ["iam:Get*", "iam:List*", "iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "${var.prefix}-runner"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.prefix}-runner"
  role = aws_iam_role.runner.name
}

# ============================ Máquina ============================

resource "aws_instance" "runner" {
  # nonsensitive: o SSM marca o valor como sensível e o id do AMI sumiria do
  # plano, sendo justamente o que identifica a imagem usada na campanha.
  ami                    = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.runner.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.runner.name
  user_data              = file("${path.module}/user-data.sh")

  root_block_device {
    volume_size = var.volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${var.prefix}-runner" }
}

# IP fixo: my_ip_cidr do experimento aponta para ele e não pode mudar entre
# stop e start no meio da campanha.
resource "aws_eip" "runner" {
  instance = aws_instance.runner.id
  domain   = "vpc"
  tags     = { Name = "${var.prefix}-runner" }
}
