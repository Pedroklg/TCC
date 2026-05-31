# =============================================================================
# Serverless (FaaS) — 6 funções spring-cloud-function × 2 subcenários
# (sem otimização "cold" × "SnapStart"), Lambda em VPC + API Gateway (HTTP, v1).
# =============================================================================

locals {
  # operação lógica -> rota REST (mesmos endpoints do monolito/micro)
  functions = {
    getAllOwners = "GET /api/owners"
    getOwnerById = "GET /api/owners/{ownerId}"
    listVets     = "GET /api/vets"
    listPetTypes = "GET /api/pettypes"
    createOwner  = "POST /api/owners"
    createVisit  = "POST /api/owners/{ownerId}/pets/{petId}/visits"
  }
  subscenarios = {
    cold = false # sem otimização
    snap = true  # SnapStart
  }
  # produto cartesiano subcenário × função: "cold-getAllOwners", "snap-getAllOwners", ...
  fn_instances = merge([
    for sname, snap in local.subscenarios : {
      for fname, route in local.functions :
      "${sname}-${fname}" => { fn = fname, route = route, snapstart = snap, sub = sname }
    }
  ]...)
}

# --- IAM da Lambda (execução + acesso à VPC para alcançar o MySQL) ---
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "lambda" {
  name               = "${var.prefix}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# --- As funções (12 = 6 × 2 subcenários) ---
resource "aws_lambda_function" "fn" {
  for_each = local.fn_instances

  function_name    = "${var.prefix}-${each.key}"
  s3_bucket        = aws_s3_bucket.artifacts.id
  s3_key           = aws_s3_object.lambda_jar.key
  source_code_hash = aws_s3_object.lambda_jar.etag
  handler          = "org.springframework.cloud.function.adapter.aws.FunctionInvoker"
  runtime          = "java17"
  memory_size      = var.lambda_memory_mb
  timeout          = 60
  role             = aws_iam_role.lambda.arn
  publish          = true # versão publicada (necessária p/ SnapStart + alias)

  vpc_config {
    subnet_ids         = aws_subnet.public[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      MAIN_CLASS                       = "org.springframework.samples.petclinic.serverless.ServerlessApplication"
      SPRING_CLOUD_FUNCTION_DEFINITION = each.value.fn
      MYSQL_URL                        = "jdbc:mysql://${aws_instance.mysql.private_ip}:3306/${var.db_name}?allowPublicKeyRetrieval=true&useSSL=false"
      MYSQL_USER                       = var.db_user
      MYSQL_PASS                       = var.db_password
    }
  }

  dynamic "snap_start" {
    for_each = each.value.snapstart ? [1] : []
    content {
      apply_on = "PublishedVersions"
    }
  }

  depends_on = [aws_s3_object.lambda_jar, aws_instance.mysql]
}

# Alias "live" -> versão publicada (SnapStart só atua via versão/alias).
resource "aws_lambda_alias" "live" {
  for_each         = aws_lambda_function.fn
  name             = "live"
  function_name    = each.value.function_name
  function_version = each.value.version
}

# --- API Gateway HTTP (uma API por subcenário => 2 URLs distintas) ---
resource "aws_apigatewayv2_api" "this" {
  for_each      = local.subscenarios
  name          = "${var.prefix}-serverless-${each.key}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "fn" {
  for_each               = local.fn_instances
  api_id                 = aws_apigatewayv2_api.this[each.value.sub].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live[each.key].invoke_arn
  payload_format_version = "1.0" # nossas funções usam APIGatewayProxyRequestEvent (v1)
}

resource "aws_apigatewayv2_route" "fn" {
  for_each  = local.fn_instances
  api_id    = aws_apigatewayv2_api.this[each.value.sub].id
  route_key = each.value.route
  target    = "integrations/${aws_apigatewayv2_integration.fn[each.key].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  for_each    = local.subscenarios
  api_id      = aws_apigatewayv2_api.this[each.key].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  for_each      = local.fn_instances
  statement_id  = "AllowAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  qualifier     = aws_lambda_alias.live[each.key].name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this[each.value.sub].execution_arn}/*/*"
}
