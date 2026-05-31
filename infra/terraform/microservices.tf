# =============================================================================
# Microsserviços — ECS Fargate, 1 service por microsserviço, descoberta via
# ECS Service Connect (mantém os hostnames config-server/discovery-server), ALB
# expõe o api-gateway. Imagens públicas oficiais (springcommunity/*).
#
# ⚠️ Braço mais complexo — validar no `terraform plan/apply` (Fase 7). Pontos de
#    atenção anotados: ordem de subida (config/discovery primeiro; os apps fazem
#    retry), health check do gateway, e a config do Service Connect.
# =============================================================================

locals {
  # service => { porta, sufixo da imagem, usa MySQL?, registra no ALB? }
  micro_services = {
    "config-server"     = { port = 8888, image = "config-server", mysql = false, alb = false }
    "discovery-server"  = { port = 8761, image = "discovery-server", mysql = false, alb = false }
    "customers-service" = { port = 8081, image = "customers-service", mysql = true, alb = false }
    "vets-service"      = { port = 8083, image = "vets-service", mysql = true, alb = false }
    "visits-service"    = { port = 8082, image = "visits-service", mysql = true, alb = false }
    "api-gateway"       = { port = 8080, image = "api-gateway", mysql = false, alb = true }
  }
}

resource "aws_cloudwatch_log_group" "micro" {
  name              = "/ecs/${var.prefix}-micro"
  retention_in_days = 7
}

resource "aws_service_discovery_http_namespace" "micro" {
  name = "${var.prefix}.local"
}

resource "aws_ecs_cluster" "micro" {
  name = "${var.prefix}-micro"
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.micro.arn
  }
}

# Papel de execução das tarefas (puxar imagem + logs).
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ecs_exec" {
  name               = "${var.prefix}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Definições de tarefa (uma por serviço).
resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.micro_services
  family                   = "${var.prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_exec.arn

  container_definitions = jsonencode([{
    name      = each.key
    image     = "springcommunity/spring-petclinic-${each.value.image}:${var.micro_image_tag}"
    essential = true
    portMappings = [{
      name          = each.key # nome exigido pelo Service Connect
      containerPort = each.value.port
      protocol      = "tcp"
    }]
    environment = concat(
      [{ name = "SPRING_PROFILES_ACTIVE", value = each.value.mysql ? "docker,mysql" : "docker" }],
      each.value.mysql ? [
        { name = "SPRING_DATASOURCE_URL", value = "jdbc:mysql://${aws_instance.mysql.private_ip}:3306/${var.db_name}?allowPublicKeyRetrieval=true&useSSL=false" },
        { name = "SPRING_DATASOURCE_USERNAME", value = "root" },
        { name = "SPRING_DATASOURCE_PASSWORD", value = var.db_password },
      ] : []
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.micro.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = each.key
      }
    }
  }])
}

# Serviços ECS (Fargate) + Service Connect.
resource "aws_ecs_service" "svc" {
  for_each        = local.micro_services
  name            = each.key
  cluster         = aws_ecs_cluster.micro.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.micro.id]
    assign_public_ip = true # puxa a imagem do Docker Hub via IGW (sem NAT)
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.micro.arn
    service {
      port_name      = each.key
      discovery_name = each.key
      client_alias {
        port     = each.value.port
        dns_name = each.key # hostname = config-server / discovery-server / ...
      }
    }
  }

  # Só o gateway vai para o ALB.
  dynamic "load_balancer" {
    for_each = each.value.alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.gateway.arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }
  health_check_grace_period_seconds = each.value.alb ? 180 : null
}

# --- ALB para o api-gateway ---
resource "aws_lb" "gateway" {
  name               = "${var.prefix}-gw"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_target_group" "gateway" {
  name        = "${var.prefix}-gw"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate awsvpc => alvos por IP
  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}
resource "aws_lb_listener" "gateway" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 8080
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}
