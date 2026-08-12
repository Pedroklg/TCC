# =============================================================================
# Microsserviços — ECS Fargate, 1 service por microsserviço, descoberta via
# ECS Service Connect (mantém os hostnames config-server/discovery-server), ALB
# expõe o api-gateway. Imagens públicas oficiais (springcommunity/*).
#
# A criação é escalonada em 3 níveis: os serviços não fazem retry e encerram se
# o config-server ainda não responde. Ver aws_ecs_service.config.
# =============================================================================

locals {
  # service => { porta, sufixo da imagem, usa MySQL?, registra no ALB? }
  micro_services = {
    "config-server"     = { port = 8888, image = "config-server", mysql = false, alb = false, cpu = 256, memory = 512 }
    "discovery-server"  = { port = 8761, image = "discovery-server", mysql = false, alb = false, cpu = 256, memory = 512 }
    "customers-service" = { port = 8081, image = "customers-service", mysql = true, alb = false, cpu = 512, memory = 1024 }
    "vets-service"      = { port = 8083, image = "vets-service", mysql = true, alb = false, cpu = 256, memory = 512 }
    "visits-service"    = { port = 8082, image = "visits-service", mysql = true, alb = false, cpu = 256, memory = 512 }
    "api-gateway"       = { port = 8080, image = "api-gateway", mysql = false, alb = true, cpu = 512, memory = 1024 }
  }
  # Soma: 2.048 unidades de CPU (2 vCPU) e 4.096 MB (4 GB) — equivalente ao monolito (c5.large).

  # Prefixo REST de cada serviço no gateway (singular, como no projeto oficial):
  # /api/vet/** -> vets-service, /api/visit/** -> visits-service, etc.
  route_prefix = {
    "vets-service"      = "vet"
    "visits-service"    = "visit"
    "customers-service" = "customer"
  }

  # Níveis de inicialização (ver comentário em aws_ecs_service.config).
  micro_platform = ["config-server", "discovery-server"]
  tier_config    = { for k, v in local.micro_services : k => v if k == "config-server" }
  tier_discovery = { for k, v in local.micro_services : k => v if k == "discovery-server" }
  tier_apps      = { for k, v in local.micro_services : k => v if !contains(local.micro_platform, k) }
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
  cpu                      = each.value.cpu
  memory                   = each.value.memory
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
      [
        { name = "SPRING_PROFILES_ACTIVE", value = each.value.mysql ? "docker,mysql" : "docker" },
        # O controller de agregação (/api/gateway/**) não passa pelas rotas abaixo:
        # ele usa um WebClient balanceado por Eureka. Registrar o hostname do
        # Service Connect, e não o IP detectado (link-local do sidecar), é o que
        # torna esse caminho interno alcançável.
        { name = "EUREKA_INSTANCE_HOSTNAME", value = each.key },
        { name = "EUREKA_INSTANCE_PREFER_IP_ADDRESS", value = "false" },
      ],
      each.value.mysql ? [
        { name = "SPRING_DATASOURCE_URL", value = "jdbc:mysql://${aws_instance.mysql.private_ip}:3306/${var.db_name}?allowPublicKeyRetrieval=true&useSSL=false" },
        { name = "SPRING_DATASOURCE_USERNAME", value = "root" },
        { name = "SPRING_DATASOURCE_PASSWORD", value = var.db_password },
      ] : [],

      # Roteamento pelo DNS do Service Connect em vez de lb:// (Eureka), que
      # registra o IP link-local do sidecar e não é alcançável entre tarefas.
      # A lista definida por variável de ambiente substitui a do config-server:
      # coleções são vinculadas de uma única fonte, e systemEnvironment vence.
      each.key == "api-gateway" ? flatten([
        for i, svc in ["vets-service", "visits-service", "customers-service"] : [
          { name = "SPRING_CLOUD_GATEWAY_ROUTES_${i}_ID", value = svc },
          { name = "SPRING_CLOUD_GATEWAY_ROUTES_${i}_URI", value = "http://${svc}:${local.micro_services[svc].port}" },
          { name = "SPRING_CLOUD_GATEWAY_ROUTES_${i}_PREDICATES_0", value = "Path=/api/${local.route_prefix[svc]}/**" },
          { name = "SPRING_CLOUD_GATEWAY_ROUTES_${i}_FILTERS_0", value = "StripPrefix=2" },
        ]
      ]) : []
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

# Serviços ECS (Fargate) + Service Connect, em 3 níveis.
#
# O DNS do Service Connect só publica o alias de um serviço depois que ele tem
# tarefa rodando; wait_for_steady_state faz o Terraform esperar cada nível antes
# de criar o próximo. O último nível mantém o nome "svc": o -target do
# orquestrador aponta para ele e o depends_on puxa os anteriores.

resource "aws_ecs_service" "config" {
  for_each              = local.tier_config
  name                  = each.key
  cluster               = aws_ecs_cluster.micro.id
  task_definition       = aws_ecs_task_definition.svc[each.key].arn
  desired_count         = 1
  launch_type           = "FARGATE"
  wait_for_steady_state = true

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
        dns_name = each.key
      }
    }
  }
}

# Nível 2 — busca configuração no config-server, por isso espera o nível 1.
resource "aws_ecs_service" "discovery" {
  for_each              = local.tier_discovery
  name                  = each.key
  cluster               = aws_ecs_cluster.micro.id
  task_definition       = aws_ecs_task_definition.svc[each.key].arn
  desired_count         = 1
  launch_type           = "FARGATE"
  wait_for_steady_state = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.micro.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.micro.arn
    service {
      port_name      = each.key
      discovery_name = each.key
      client_alias {
        port     = each.value.port
        dns_name = each.key
      }
    }
  }

  depends_on = [aws_ecs_service.config]
}

# Nível 3 — serviços de negócio + gateway: precisam de config E de Eureka.
resource "aws_ecs_service" "svc" {
  for_each        = local.tier_apps
  name            = each.key
  cluster         = aws_ecs_cluster.micro.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.micro.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.micro.arn
    service {
      port_name      = each.key
      discovery_name = each.key
      client_alias {
        port     = each.value.port
        dns_name = each.key
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

  depends_on = [aws_ecs_service.discovery]
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
