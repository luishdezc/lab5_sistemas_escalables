# Lambdas: consumidora (Kinesis -> Redshift) y productora opcional (API GW -> Kinesis).
# Ambas usan LabRole como rol de ejecución.

# ---------------------------------------------------------------------------
# Consumidora
# ---------------------------------------------------------------------------

data "archive_file" "consumer" {
  type        = "zip"
  source_file = "${path.module}/../lambda/consumer/handler.py"
  output_path = "${path.module}/build/consumer.zip"
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/aws/lambda/${local.name}-consumer"
  retention_in_days = 3
}

resource "aws_lambda_function" "consumer" {
  function_name    = "${local.name}-consumer"
  role             = local.lab_role
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256
  timeout          = 60
  memory_size      = 256

  # Pocas ejecuciones simultáneas = pocas llamadas a la Data API.
  reserved_concurrent_executions = var.consumer_reserved_concurrency

  environment {
    variables = {
      RS_CLUSTER    = aws_redshift_cluster.this.cluster_identifier
      RS_DATABASE   = aws_redshift_cluster.this.database_name
      RS_SECRET_ARN = aws_secretsmanager_secret.redshift.arn
      RS_TABLE      = "public.events"
    }
  }

  depends_on = [aws_cloudwatch_log_group.consumer]
}

# Event source mapping pensado para pocas invocaciones y lotes grandes.
resource "aws_lambda_event_source_mapping" "kinesis" {
  function_name     = aws_lambda_function.consumer.arn
  event_source_arn  = local.stream_arn
  starting_position = "TRIM_HORIZON"

  batch_size                         = 500
  maximum_batching_window_in_seconds = 10
  parallelization_factor             = 1
  maximum_retry_attempts             = 2
  bisect_batch_on_function_error     = true
  function_response_types            = ["ReportBatchItemFailures"]

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn
    }
  }

  # La tabla debe existir antes de que lleguen inserts (la Lambda no hace polling
  # del resultado, así que un INSERT sobre tabla inexistente se perdería).
  depends_on = [null_resource.create_table, null_resource.kinesis_stream]
}

# ---------------------------------------------------------------------------
# Productora (solo si api_integration_mode = "lambda")
# ---------------------------------------------------------------------------

data "archive_file" "producer" {
  count       = var.api_integration_mode == "lambda" ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/../lambda/producer/handler.py"
  output_path = "${path.module}/build/producer.zip"
}

resource "aws_cloudwatch_log_group" "producer" {
  count             = var.api_integration_mode == "lambda" ? 1 : 0
  name              = "/aws/lambda/${local.name}-producer"
  retention_in_days = 3
}

resource "aws_lambda_function" "producer" {
  count            = var.api_integration_mode == "lambda" ? 1 : 0
  function_name    = "${local.name}-producer"
  role             = local.lab_role
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.producer[0].output_path
  source_code_hash = data.archive_file.producer[0].output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      STREAM_NAME = local.stream_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]
}

resource "aws_lambda_permission" "apigw_producer" {
  count         = var.api_integration_mode == "lambda" ? 1 : 0
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.producer[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/events"
}
