#!/usr/bin/env bash
# Invocado por null_resource.kinesis_stream (terraform/kinesis.tf).
#   create: adopta el stream si ya existe; si no, lo crea en ON_DEMAND y espera ACTIVE
#           (backoff 5, 10, 20, 30... s, máximo 10 consultas).
#   delete: borra el stream (una llamada, sin esperar).
# Sin reintentos: si algo falla, falla el apply/destroy.
set -euo pipefail
: "${STREAM_NAME:?}"

stream_status() {
  aws kinesis describe-stream-summary --stream-name "$STREAM_NAME" \
    --query 'StreamDescriptionSummary.StreamStatus' --output text --no-cli-pager 2>/dev/null
}

case "${1:-}" in
  create)
    if status=$(stream_status); then
      echo "Stream ${STREAM_NAME} ya existe (estado=${status}); se adopta."
      [ "$status" = "ACTIVE" ] && exit 0
    else
      echo "Creando stream ${STREAM_NAME} en modo ON_DEMAND..."
      aws kinesis create-stream --stream-name "$STREAM_NAME" \
        --stream-mode-details StreamMode=ON_DEMAND --no-cli-pager
    fi
    delay=5
    for attempt in $(seq 1 10); do
      sleep "$delay"
      status=$(stream_status) || status="DESCONOCIDO"
      echo "  intento ${attempt}/10: estado=${status}"
      [ "$status" = "ACTIVE" ] && exit 0
      delay=$((delay * 2))
      [ "$delay" -gt 30 ] && delay=30
    done
    echo "ERROR: el stream no llegó a ACTIVE tras 10 consultas." >&2
    exit 1
    ;;
  delete)
    echo "Borrando stream ${STREAM_NAME}..."
    aws kinesis delete-stream --stream-name "$STREAM_NAME" --enforce-consumer-deletion --no-cli-pager
    ;;
  *)
    echo "uso: $0 create|delete" >&2
    exit 2
    ;;
esac
