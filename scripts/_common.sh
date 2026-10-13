#!/usr/bin/env bash
# Funciones compartidas por los scripts. Sin bucles agresivos ni reintentos en cadena.

# Espera a que termine un statement de la Redshift Data API.
# Backoff exponencial: 5, 10, 20, 30, 30, ... segundos (tope 30 s), máximo 10 consultas.
# Uso: wait_statement <statement_id>   -> imprime el estado final; retorna 0 si FINISHED.
# Deja en STMT_DURATION_NS la duración en servidor (ns) que reporta la Data API,
# obtenida en la misma consulta de estado (sin llamadas extra).
wait_statement() {
  local id="$1" delay=5 attempt status out
  STMT_DURATION_NS=""
  for attempt in $(seq 1 10); do
    sleep "$delay"
    out=$(aws redshift-data describe-statement --id "$id" \
      --query '[Status, Duration]' --output text --no-cli-pager) || {
      echo "ERROR: describe-statement falló (¿credenciales expiradas?). No se reintenta." >&2
      return 2
    }
    read -r status STMT_DURATION_NS <<<"$out"
    echo "  intento ${attempt}/10: estado=${status}" >&2
    case "$status" in
      FINISHED) return 0 ;;
      FAILED | ABORTED)
        aws redshift-data describe-statement --id "$id" --query 'Error' --output text --no-cli-pager >&2
        return 1
        ;;
    esac
    delay=$((delay * 2))
    [ "$delay" -gt 30 ] && delay=30
  done
  echo "ERROR: el statement ${id} no terminó tras 10 consultas." >&2
  return 1
}

# Pide confirmación s/n; sale si la respuesta no es "s".
confirm() {
  local answer
  read -r -p "$1 [s/n]: " answer
  [ "$answer" = "s" ] || { echo "Cancelado."; exit 1; }
}
