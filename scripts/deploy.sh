#!/usr/bin/env bash
# Despliegue completo con validaciones locales primero y confirmación antes de tocar AWS.
# Un solo plan (guardado en tfplan) y un solo apply de ese plan, ambos con -parallelism=3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/_common.sh"
cd "$ROOT"

echo "== 1/4 Validaciones locales (sin AWS) =="
python3 -m unittest discover -s lambda/consumer/tests
python3 -m unittest discover -s lambda/producer/tests
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate

[ -f terraform/terraform.tfvars ] || { echo "Falta terraform/terraform.tfvars (copia el .example)"; exit 1; }

echo "== 2/4 Preflight mínimo (2 llamadas) =="
confirm "¿Ejecutar sts get-caller-identity e iam get-role LabRole?"
aws sts get-caller-identity --no-cli-pager
aws iam get-role --role-name LabRole --query 'Role.AssumeRolePolicyDocument.Statement[].Principal.Service' --output json --no-cli-pager

echo "== 3/4 terraform plan =="
confirm "¿Ejecutar UN terraform plan -parallelism=3?"
terraform -chdir=terraform plan -parallelism=3 -input=false -out=tfplan

echo "== 4/4 terraform apply =="
confirm "¿Aplicar el plan guardado (tfplan)?"
terraform -chdir=terraform apply -parallelism=3 -input=false tfplan

terraform -chdir=terraform output
