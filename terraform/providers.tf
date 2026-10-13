# Proveedores y configuración base del laboratorio.
# El estado es LOCAL (terraform.tfstate en esta carpeta), como exige el Learner Lab.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.region

  # Las credenciales se toman del entorno / ~/.aws/credentials (temporales del Learner Lab).
  # Nunca se escriben aquí.

  # Limitamos los reintentos internos del SDK para no multiplicar llamadas si algo falla.
  max_retries = 2

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Lab       = "lab5-streaming"
    }
  }
}

# Identidad y región actuales: evitan hardcodear el account ID.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Rol preexistente del Learner Lab. No se pueden crear roles ni políticas IAM.
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

locals {
  name       = var.project_name
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  lab_role   = data.aws_iam_role.lab_role.arn
}
