# Cola de fallos (destino on-failure del event source mapping).
# Kinesis envía aquí los METADATOS del lote fallido (shard, rango de secuencias),
# no el payload; con eso se pueden releer los registros del stream.

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-consumer-dlq"
  message_retention_seconds = 345600 # 4 días
  sqs_managed_sse_enabled   = true
}
