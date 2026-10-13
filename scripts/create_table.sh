#!/usr/bin/env bash
# Invocado por null_resource.create_table (terraform/redshift.tf).
# UN solo execute-statement + espera con backoff. Si falla, falla el apply (sin reintentos).
set -euo pipefail
source "$(dirname "$0")/_common.sh"

: "${RS_CLUSTER:?}" "${RS_DATABASE:?}" "${RS_SECRET_ARN:?}" "${RS_SQL:?}"

echo "Creando tabla public.events en ${RS_CLUSTER}/${RS_DATABASE}..."
id=$(aws redshift-data execute-statement \
  --cluster-identifier "$RS_CLUSTER" \
  --database "$RS_DATABASE" \
  --secret-arn "$RS_SECRET_ARN" \
  --sql "$RS_SQL" \
  --statement-name lab5-create-table \
  --query 'Id' --output text --no-cli-pager)
echo "Statement ID: ${id}"

wait_statement "$id"
echo "Tabla lista."
