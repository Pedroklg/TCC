output "monolith_base_url" {
  description = "BASE_URL do k6 para o monolito"
  value       = "http://${aws_instance.monolith.public_ip}:9966/petclinic/api"
}

output "microservices_base_url" {
  description = "BASE_URL do k6 para os microsserviços (ALB do gateway)"
  value       = "http://${aws_lb.gateway.dns_name}:8080/api"
}

output "serverless_cold_base_url" {
  description = "BASE_URL do k6 para o serverless SEM otimização"
  value       = "${trimsuffix(aws_apigatewayv2_stage.default["cold"].invoke_url, "/")}/api"
}

output "serverless_snap_base_url" {
  description = "BASE_URL do k6 para o serverless com SnapStart"
  value       = "${trimsuffix(aws_apigatewayv2_stage.default["snap"].invoke_url, "/")}/api"
}

output "monolith_instance_id" {
  description = "ID da EC2 do monolito (para captura de CPU no CloudWatch)"
  value       = aws_instance.monolith.id
}
output "mysql_instance_id" {
  description = "ID da EC2 do MySQL (captura de CPU no CloudWatch)"
  value       = aws_instance.mysql.id
}
output "mysql_private_ip" {
  value = aws_instance.mysql.private_ip
}
output "mysql_public_ip" {
  description = "IP público do MySQL (SSH só do seu IP) para inspeção/seed manual"
  value       = aws_instance.mysql.public_ip
}
output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.id
}

output "k6_commands" {
  description = "Comandos prontos para a bateria de carga (após o apply)"
  value       = <<-EOT
    .\load-tests\run-all.ps1 -Target mono       -BaseUrl http://${aws_instance.monolith.public_ip}:9966/petclinic/api -Reps 10
    .\load-tests\run-all.ps1 -Target micro      -BaseUrl http://${aws_lb.gateway.dns_name}:8080/api -Reps 10
    .\load-tests\run-all.ps1 -Target serverless -Label serverless-cold -BaseUrl ${trimsuffix(aws_apigatewayv2_stage.default["cold"].invoke_url, "/")}/api -Reps 10
    .\load-tests\run-all.ps1 -Target serverless -Label serverless-snap -BaseUrl ${trimsuffix(aws_apigatewayv2_stage.default["snap"].invoke_url, "/")}/api -Reps 10
  EOT
}
