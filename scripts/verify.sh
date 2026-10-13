#!/usr/bin/env bash
# Verificación tras la prueba de carga:
#  - espera 60 s (ventana de batching + procesamiento),
#  - UNA consulta a Redshift (COUNT(*) y COUNT(DISTINCT event_id) en la misma sentencia),
#  - UNA consulta a la DLQ (ApproximateNumberOfMessages).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/_common.sh"

# terraform output lee el estado local: no llama a AWS.
tf_out() { terraform -chdir="$ROOT/terraform" output -raw "$1"; }
CLUSTER=$(tf_out redshift_cluster)
DB=$(tf_out redshift_database)
SECRET=$(tf_out redshift_secret_arn)
DLQ=$(tf_out dlq_url)

WAIT="${WAIT_SECONDS:-60}"
echo "Esperando ${WAIT} s para que el consumidor procese los lotes..."
sleep "$WAIT"

echo "== Redshift: conteo de eventos =="
SQL="SELECT COUNT(*) AS total, COUNT(DISTINCT event_id) AS distintos, MAX(ingested_at) AS ultimo FROM public.events"
id=$(aws redshift-data execute-statement --cluster-identifier "$CLUSTER" --database "$DB" \
  --secret-arn "$SECRET" --sql "$SQL" --statement-name lab5-verify \
  --query 'Id' --output text --no-cli-pager)
echo "Statement ID: ${id}"
wait_statement "$id"
aws redshift-data get-statement-result --id "$id" --no-cli-pager \
  --query '{total: Records[0][0].longValue, distintos: Records[0][1].longValue, ultimo_ingested_at: Records[0][2].stringValue}' \
  --output table

echo "== SQS DLQ: mensajes de lotes fallidos =="
aws sqs get-queue-attributes --queue-url "$DLQ" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' --output text --no-cli-pager
