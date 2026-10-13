# Variables del laboratorio. Los valores por defecto están pensados para
# minimizar costo y número de llamadas a AWS.

variable "project_name" {
  description = "Prefijo para nombrar todos los recursos."
  type        = string
  default     = "lab5"
}

variable "region" {
  description = "Región de AWS (el Learner Lab trabaja en us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "my_ip_cidr" {
  description = "Tu IP pública en formato CIDR (ej. 203.0.113.10/32). Único origen permitido al puerto 3000 de Grafana."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr debe ser un CIDR válido, por ejemplo 203.0.113.10/32."
  }
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------

variable "api_integration_mode" {
  description = <<-EOT
    "direct": API Gateway llama a Kinesis PutRecord asumiendo LabRole (requiere que
    apigateway.amazonaws.com esté en la trust policy de LabRole).
    "lambda": una Lambda productora intermedia escribe en Kinesis.
  EOT
  type        = string
  default     = "direct"

  validation {
    condition     = contains(["direct", "lambda"], var.api_integration_mode)
    error_message = "api_integration_mode debe ser \"direct\" o \"lambda\"."
  }
}

variable "api_throttle_rate_limit" {
  description = "Requests/segundo sostenidos permitidos en el stage (conservador para el lab)."
  type        = number
  default     = 20
}

variable "api_throttle_burst_limit" {
  description = "Ráfaga máxima permitida en el stage."
  type        = number
  default     = 40
}

# ---------------------------------------------------------------------------
# Lambda consumidora
# ---------------------------------------------------------------------------

variable "consumer_reserved_concurrency" {
  description = <<-EOT
    Concurrencia reservada de la Lambda consumidora (limita llamadas a la Data API).
    Si el apply falla con "decreases account's UnreservedConcurrentExecution below
    its minimum value", la cuenta tiene un límite de 10; usa -1 (sin reserva).
  EOT
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Redshift (provisionado: el Learner Lab no permite Redshift Serverless)
# ---------------------------------------------------------------------------

variable "redshift_node_type" {
  description = "Tipo de nodo del cluster single-node. Debe estar permitido en el Readme del Learner Lab."
  type        = string
  default     = "ra3.large" # dc2.large ya no es válido (InvalidParameterValue)
}

variable "redshift_az_ids" {
  description = <<-EOT
    IDs de AZ (no nombres) donde se buscan subnets de la VPC por defecto para el
    subnet group de Redshift. use1-az3 se excluye por tener soporte limitado de Redshift.
  EOT
  type        = list(string)
  default     = ["use1-az1", "use1-az2", "use1-az4", "use1-az5", "use1-az6"]
}

variable "redshift_extra_ingress_cidrs" {
  description = "CIDRs adicionales permitidos al puerto 5439 (además de la VPC). Vacío por defecto."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------

variable "enable_grafana_ec2" {
  description = "Plan B: Grafana OSS en una EC2 t3.micro (camino que funciona en el Learner Lab)."
  type        = bool
  default     = true
}

variable "enable_managed_grafana" {
  description = <<-EOT
    Plan A: Amazon Managed Grafana. Requiere IAM Identity Center o un IdP SAML para
    iniciar sesión, que el Learner Lab normalmente no permite. Desactivado por defecto.
  EOT
  type        = bool
  default     = false
}

variable "grafana_instance_type" {
  description = "Tipo de instancia para Grafana OSS."
  type        = string
  default     = "t3.micro"
}
