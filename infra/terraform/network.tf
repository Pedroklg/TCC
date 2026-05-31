# VPC dedicada (fácil de destruir; SEM NAT). Tudo em subnets públicas (IGW grátis).
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.prefix}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ============================ Security Groups ============================

# Monolito: 9966 (k6) e 22 (SSH) só do seu IP.
resource "aws_security_group" "mono" {
  name   = "${var.prefix}-mono"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 9966
    to_port     = 9966
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-mono" }
}

# ALB do micro: 8080 só do seu IP.
resource "aws_security_group" "alb" {
  name   = "${var.prefix}-alb"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-alb" }
}

# Tarefas Fargate: recebem do ALB (gateway) e conversam entre si (Service Connect/Eureka).
resource "aws_security_group" "micro" {
  name   = "${var.prefix}-micro"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-micro" }
}

# Tráfego entre as próprias tarefas micro (registro Eureka + chamadas internas).
resource "aws_security_group_rule" "micro_self" {
  type                     = "ingress"
  security_group_id        = aws_security_group.micro.id
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.micro.id
}

# Lambda em VPC: só egress (alcança o MySQL; não precisa de internet).
resource "aws_security_group" "lambda" {
  name   = "${var.prefix}-lambda"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-lambda" }
}

# MySQL: 3306 APENAS dos SGs das apps (mono, micro, lambda). Sem exposição pública.
resource "aws_security_group" "mysql" {
  name   = "${var.prefix}-mysql"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-mysql" }
}
# 22 (SSH) no MySQL só do seu IP (para semear/depurar)
resource "aws_security_group_rule" "mysql_ssh" {
  type              = "ingress"
  security_group_id = aws_security_group.mysql.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]
}
resource "aws_security_group_rule" "mysql_from_mono" {
  type                     = "ingress"
  security_group_id        = aws_security_group.mysql.id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.mono.id
}
resource "aws_security_group_rule" "mysql_from_micro" {
  type                     = "ingress"
  security_group_id        = aws_security_group.mysql.id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.micro.id
}
resource "aws_security_group_rule" "mysql_from_lambda" {
  type                     = "ingress"
  security_group_id        = aws_security_group.mysql.id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda.id
}
