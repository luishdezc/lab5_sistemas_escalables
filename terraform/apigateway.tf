# API Gateway REST: POST /events con validación de JSON schema y throttling
# conservador. Dos modos de integración (ver var.api_integration_mode).

locals {
  direct_mode = var.api_integration_mode == "direct"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${local.name}-ingest"
  description = "Ingesta de eventos del lab5 hacia Kinesis"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "events"
}

# Esquema del evento. API Gateway rechaza con 400 lo que no cumpla, antes de
# tocar Kinesis (protege el pipeline de basura y ahorra llamadas).
resource "aws_api_gateway_model" "event" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "Event"
  content_type = "application/json"

  schema = jsonencode({
    "$schema"            = "http://json-schema.org/draft-04/schema#"
    title                = "Event"
    type                 = "object"
    additionalProperties = false
    required             = ["device_id", "event_type", "value", "event_ts"]
    properties = {
      event_id   = { type = "string", pattern = "^[A-Za-z0-9_.:-]{1,64}$" }
      device_id  = { type = "string", pattern = "^[A-Za-z0-9_.:-]{1,64}$" }
      event_type = { type = "string", pattern = "^[A-Za-z0-9_-]{1,32}$" }
      value      = { type = "number" }
      # ISO 8601, ej. 2026-10-13T18:00:00.123Z
      event_ts = {
        type    = "string"
        pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})?$"
      }
    }
  })
}

resource "aws_api_gateway_request_validator" "body" {
  rest_api_id           = aws_api_gateway_rest_api.this.id
  name                  = "validate-body"
  validate_request_body = true
}

resource "aws_api_gateway_method" "post_events" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.events.id
  http_method          = "POST"
  authorization        = "NONE"
  request_validator_id = aws_api_gateway_request_validator.body.id

  request_models = {
    "application/json" = aws_api_gateway_model.event.name
  }
}

# Mensaje de error de validación legible para el cliente.
resource "aws_api_gateway_gateway_response" "bad_body" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "BAD_REQUEST_BODY"
  status_code   = "400"

  response_templates = {
    "application/json" = "{\"message\": \"body invalido\", \"detail\": \"$context.error.validationErrorString\"}"
  }
}

# ---------------------------------------------------------------------------
# Modo "direct": API Gateway -> Kinesis PutRecord (asume LabRole)
# ---------------------------------------------------------------------------

resource "aws_api_gateway_integration" "kinesis" {
  count                   = local.direct_mode ? 1 : 0
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${local.region}:kinesis:action/PutRecord"
  credentials             = local.lab_role
  passthrough_behavior    = "NEVER"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-amz-json-1.1'"
  }

  # El body completo (ya validado) va en Data; device_id es la partition key.
  request_templates = {
    "application/json" = <<-VTL
      {
        "StreamName": "${local.stream_name}",
        "Data": "$util.base64Encode($input.json('$'))",
        "PartitionKey": "$input.path('$.device_id')"
      }
    VTL
  }

  depends_on = [null_resource.kinesis_stream]
}

resource "aws_api_gateway_method_response" "ok" {
  count       = local.direct_mode ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "200"
}

resource "aws_api_gateway_method_response" "error" {
  count       = local.direct_mode ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = "502"
}

resource "aws_api_gateway_integration_response" "ok" {
  count       = local.direct_mode ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.post_events.http_method
  status_code = aws_api_gateway_method_response.ok[0].status_code

  response_templates = {
    "application/json" = "{\"status\": \"accepted\", \"sequence_number\": \"$input.path('$.SequenceNumber')\", \"shard_id\": \"$input.path('$.ShardId')\"}"
  }

  depends_on = [aws_api_gateway_integration.kinesis]
}

# Cualquier 4xx/5xx de Kinesis se devuelve como 502 (sin reintentos).
resource "aws_api_gateway_integration_response" "error" {
  count             = local.direct_mode ? 1 : 0
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.events.id
  http_method       = aws_api_gateway_method.post_events.http_method
  status_code       = aws_api_gateway_method_response.error[0].status_code
  selection_pattern = "[45]\\d{2}"

  response_templates = {
    "application/json" = "{\"status\": \"error\", \"type\": \"$input.path('$.__type')\"}"
  }

  depends_on = [aws_api_gateway_integration.kinesis]
}

# ---------------------------------------------------------------------------
# Modo "lambda": API Gateway -> Lambda productora (proxy)
# ---------------------------------------------------------------------------

resource "aws_api_gateway_integration" "producer" {
  count                   = local.direct_mode ? 0 : 1
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.post_events.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.producer[0].invoke_arn
}

# ---------------------------------------------------------------------------
# Despliegue y stage con throttling
# ---------------------------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redespliega cuando cambia cualquier pieza de la API.
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_method.post_events.id,
      aws_api_gateway_model.event.schema,
      aws_api_gateway_gateway_response.bad_body.response_templates,
      aws_api_gateway_integration.kinesis[*].request_templates,
      aws_api_gateway_integration_response.ok[*].id,
      aws_api_gateway_integration_response.error[*].id,
      aws_api_gateway_integration.producer[*].uri,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.kinesis,
    aws_api_gateway_integration_response.ok,
    aws_api_gateway_integration_response.error,
    aws_api_gateway_integration.producer,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "prod"
}

# Throttling para todos los métodos del stage. Valores bajos a propósito para el
# Learner Lab; en producción se subirían (ver README).
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
    metrics_enabled        = false
  }
}
