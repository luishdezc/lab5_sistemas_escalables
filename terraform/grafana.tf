# Visualización.
# Plan A (opcional): Amazon Managed Grafana. Plan B (por defecto): Grafana OSS en EC2.

# ---------------------------------------------------------------------------
# Plan A: Amazon Managed Grafana
# ---------------------------------------------------------------------------
# Managed Grafana exige IAM Identity Center (AWS_SSO) o SAML para iniciar sesión.
# El Learner Lab no permite habilitar Identity Center y no hay IdP SAML, así que el
# workspace se puede crear pero nadie podría entrar. Por eso viene desactivado.

resource "aws_grafana_workspace" "managed" {
  count                    = var.enable_managed_grafana ? 1 : 0
  name                     = "${local.name}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["SAML"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = local.lab_role
  data_sources             = ["REDSHIFT"]
}

# ---------------------------------------------------------------------------
# Plan B: Grafana OSS en EC2 t3.micro con LabInstanceProfile
# ---------------------------------------------------------------------------

# Amazon Linux 2023 más reciente (una llamada DescribeImages).
data "aws_ami" "al2023" {
  count       = var.enable_grafana_ec2 ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

resource "aws_security_group" "grafana" {
  count       = var.enable_grafana_ec2 ? 1 : 0
  name        = "${local.name}-grafana-sg"
  description = "Grafana 3000 solo desde la IP del usuario"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Grafana UI desde mi IP"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    description = "Salida para instalar paquetes y llamar a la Data API"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  grafana_datasource_yaml = templatefile("${path.module}/../grafana/provisioning/datasources/redshift.yaml.tftpl", {
    region      = local.region
    cluster     = aws_redshift_cluster.this.cluster_identifier
    database    = aws_redshift_cluster.this.database_name
    secret_arn  = aws_secretsmanager_secret.redshift.arn
    secret_name = aws_secretsmanager_secret.redshift.name
  })
  grafana_dashboards_yaml = file("${path.module}/../grafana/provisioning/dashboards/lab5.yaml")
  grafana_dashboard_json  = file("${path.module}/../grafana/dashboards/lab5-streaming.json")
}

resource "aws_instance" "grafana" {
  count                       = var.enable_grafana_ec2 ? 1 : 0
  ami                         = data.aws_ami.al2023[0].id
  instance_type               = var.grafana_instance_type
  subnet_id                   = local.redshift_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.grafana[0].id]
  associate_public_ip_address = true
  iam_instance_profile        = "LabInstanceProfile"

  # user_data comprimido (gzip) para no superar el límite de 16 KB.
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/grafana_user_data.sh.tftpl", {
    admin_password  = random_password.grafana_admin.result
    datasource_yaml = local.grafana_datasource_yaml
    dashboards_yaml = local.grafana_dashboards_yaml
    dashboard_json  = local.grafana_dashboard_json
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
  }

  tags = {
    Name = "${local.name}-grafana"
  }

  depends_on = [null_resource.create_table]
}
