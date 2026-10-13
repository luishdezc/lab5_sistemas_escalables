#!/usr/bin/env bash
# Destruye todo lo creado por Terraform (un solo destroy con -parallelism=3).
# - La confirmación la pide este script, por eso se usa -auto-approve
#   (con -input=false Terraform no puede preguntar "yes" y fallaría).
# - -refresh=false: no vuelve a leer cada recurso en AWS antes de borrarlo (menos llamadas).
# - El stream de Kinesis lo borra el provisioner de destroy de null_resource.kinesis_stream.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/_common.sh"

confirm "Esto borra API, Kinesis, Lambdas, Redshift, Grafana y la DLQ. ¿Continuar?"
terraform -chdir="$ROOT/terraform" destroy -parallelism=3 -input=false -refresh=false -auto-approve

# Comprobación local (no llama a AWS): el estado debe quedar vacío.
left=$(terraform -chdir="$ROOT/terraform" state list 2>/dev/null || true)
if [ -n "$left" ]; then
  echo "AVISO: quedaron recursos en el estado:"
  echo "$left"
  exit 1
fi
echo "Estado vacío: todos los recursos fueron destruidos."
