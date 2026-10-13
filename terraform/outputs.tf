# Salidas útiles para probar y verificar. Leerlas (terraform output) NO llama a AWS.

output "api_endpoint" {
  description = "URL del endpoint POST /events"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/events"
}

output "api_integration_mode" {
  description = "Modo de integración usado (direct o lambda)"
  value       = var.api_integration_mode
}

output "kinesis_stream_name" {
  value = local.stream_name
}

output "redshift_cluster" {
  value = aws_redshift_cluster.this.cluster_identifier
}

output "redshift_database" {
  value = aws_redshift_cluster.this.database_name
}

output "redshift_endpoint" {
  description = "Endpoint JDBC/psql del cluster de Redshift (host:puerto)"
  value       = aws_redshift_cluster.this.endpoint
}

output "redshift_secret_arn" {
  description = "Secreto usado por la Data API (no contiene la contraseña en el output)"
  value       = aws_secretsmanager_secret.redshift.arn
}

output "grafana_url" {
  value = var.enable_grafana_ec2 ? "http://${aws_instance.grafana[0].public_ip}:3000" : (
    var.enable_managed_grafana ? "https://${aws_grafana_workspace.managed[0].endpoint}" : "grafana deshabilitado"
  )
}

output "grafana_admin_password" {
  description = "Usuario admin de Grafana OSS (terraform output -raw grafana_admin_password)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "dlq_url" {
  description = "Cola SQS de lotes fallidos"
  value       = aws_sqs_queue.dlq.url
}

output "consumer_function_name" {
  value = aws_lambda_function.consumer.function_name
}
