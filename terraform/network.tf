# Red: se usa la VPC por defecto (no se crean VPCs nuevas).

data "aws_vpc" "default" {
  default = true
}

# Una sola llamada: subnets por defecto de la VPC, filtradas a AZs con buen soporte
# de Redshift (para el subnet group del cluster).
data "aws_subnets" "redshift" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone-id"
    values = var.redshift_az_ids
  }
}

locals {
  # Orden estable para que el plan no cambie entre ejecuciones.
  redshift_subnet_ids = sort(data.aws_subnets.redshift.ids)
}

# Security group de Redshift: 5439 solo desde la VPC (incluye la EC2 de Grafana)
# y desde CIDRs extra opcionales. La Lambda y Grafana usan la Data API (HTTPS
# gestionado por AWS), así que no necesitan este puerto, pero se deja acotado.
resource "aws_security_group" "redshift" {
  name        = "${local.name}-redshift-sg"
  description = "Redshift 5439 solo desde la VPC y origenes de Grafana"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Redshift desde la VPC por defecto (incluye EC2 de Grafana)"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = concat([data.aws_vpc.default.cidr_block], var.redshift_extra_ingress_cidrs)
  }

  egress {
    description = "Salida libre"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
