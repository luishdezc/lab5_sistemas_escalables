# Kinesis Data Streams en modo ON_DEMAND: escala shards automáticamente,
# sin gestión manual de capacidad.
#
# No se usa aws_kinesis_stream: tras crear el stream, el provider siempre llama a
# IncreaseStreamRetentionPeriod, acción que la SCP del Learner Lab deniega
# explícitamente. El stream se crea con la CLI (CreateStream sí está permitido)
# y se queda con la retención por defecto de 24 h.

locals {
  stream_name = "${local.name}-events"
  stream_arn  = "arn:aws:kinesis:${local.region}:${local.account_id}:stream/${local.stream_name}"
}

resource "null_resource" "kinesis_stream" {
  triggers = {
    name   = local.stream_name
    region = local.region
  }

  # Crea el stream (o adopta uno existente) y espera ACTIVE con backoff.
  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/kinesis_stream.sh create"
    environment = {
      AWS_REGION  = self.triggers.region
      STREAM_NAME = self.triggers.name
    }
  }

  # Borra el stream en terraform destroy.
  provisioner "local-exec" {
    when    = destroy
    command = "bash ${path.module}/../scripts/kinesis_stream.sh delete"
    environment = {
      AWS_REGION  = self.triggers.region
      STREAM_NAME = self.triggers.name
    }
  }
}
