# Amazon Redshift (almacén columnar).
#
# El Learner Lab NO permite Redshift Serverless (redshift-serverless:CreateNamespace
# no está en la política), así que se usa un cluster PROVISIONADO de un solo nodo.
# Todo lo demás (Data API con secreto, tabla, Lambda, Grafana) funciona igual.

# Contraseña del admin generada por Terraform. Redshift no acepta ' " \ / @ ni espacios.
resource "random_password" "redshift_admin" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
}

resource "aws_redshift_subnet_group" "this" {
  name        = "${local.name}-redshift-subnets"
  description = "Subnets de la VPC por defecto para Redshift"
  subnet_ids  = local.redshift_subnet_ids
}

resource "aws_redshift_cluster" "this" {
  cluster_identifier = "${local.name}-cluster"
  database_name      = "streaming"
  master_username    = "lab5admin"
  master_password    = random_password.redshift_admin.result

  node_type    = var.redshift_node_type
  cluster_type = "single-node"

  # RA3 se crea cifrado y con reubicación de AZ activada; se declaran igual que en
  # AWS para que Terraform no intente cambiarlos (descifrar es una modificación larga).
  encrypted                            = true
  availability_zone_relocation_enabled = true

  publicly_accessible       = true
  cluster_subnet_group_name = aws_redshift_subnet_group.this.name
  vpc_security_group_ids    = [aws_security_group.redshift.id]

  # LabRole es el único rol disponible en el Learner Lab.
  iam_roles            = [local.lab_role]
  default_iam_role_arn = local.lab_role

  # RA3 no permite desactivar los snapshots automáticos (mínimo 1 día).
  # Sin snapshot final al destruir.
  automated_snapshot_retention_period = 1
  skip_final_snapshot                 = true
}

# Secreto con usuario/contraseña del admin. La Data API lo usa (SecretArn) tanto
# desde Terraform (crear tabla) como desde la Lambda y Grafana, de modo que todos
# actúan como el mismo usuario dueño de la tabla (evita problemas de GRANT).
resource "aws_secretsmanager_secret" "redshift" {
  name                    = "${local.name}-redshift-admin"
  description             = "Credenciales admin de Redshift para la Data API (lab5)"
  recovery_window_in_days = 0 # borrado inmediato en destroy

  tags = {
    # Etiqueta que exige la política gestionada AmazonRedshiftDataFullAccess.
    RedshiftDataFullAccess = "lab5"
  }
}

resource "aws_secretsmanager_secret_version" "redshift" {
  secret_id = aws_secretsmanager_secret.redshift.id
  secret_string = jsonencode({
    username            = aws_redshift_cluster.this.master_username
    password            = random_password.redshift_admin.result
    engine              = "redshift"
    dbClusterIdentifier = aws_redshift_cluster.this.cluster_identifier
  })
}

locals {
  events_table_ddl = <<-SQL
    CREATE TABLE IF NOT EXISTS public.events (
      event_id VARCHAR(64),
      device_id VARCHAR(64),
      event_type VARCHAR(32),
      value DOUBLE PRECISION,
      event_ts TIMESTAMP,
      ingested_at TIMESTAMP DEFAULT GETDATE()
    ) DISTKEY(device_id) SORTKEY(event_ts);
  SQL
}

# Crea la tabla con UN solo execute-statement y espera con backoff exponencial
# (5 s inicial, máx. 10 consultas de estado). Se ejecuta con las credenciales locales.
resource "null_resource" "create_table" {
  triggers = {
    cluster  = aws_redshift_cluster.this.id
    ddl_hash = sha256(local.events_table_ddl)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/create_table.sh"
    environment = {
      AWS_REGION    = local.region
      RS_CLUSTER    = aws_redshift_cluster.this.cluster_identifier
      RS_DATABASE   = aws_redshift_cluster.this.database_name
      RS_SECRET_ARN = aws_secretsmanager_secret.redshift.arn
      RS_SQL        = local.events_table_ddl
    }
  }

  depends_on = [aws_secretsmanager_secret_version.redshift]
}
