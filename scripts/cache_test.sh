#!/usr/bin/env bash
# Comparación de rendimiento: consulta con la caché de resultados de Redshift VACÍA
# frente a la misma consulta con la caché CARGADA.
#
# Corridas (misma consulta agregada sobre public.events):
#   1) sin caché: SET enable_result_cache_for_session TO off + consulta (misma sesión)
#   2) primera ejecución con caché habilitada: calcula y llena la caché
#   3) segunda ejecución: debe servirse desde la caché de resultados
# Luego UNA consulta a SYS_QUERY_HISTORY confirma result_cache_hit y tiempos internos.
#
# Llamadas a AWS: 4 execute-statement + describe-statement con backoff + 1 get-statement-result
# (unas 12 en total). Sin reintentos. Ejecutar DESPUÉS de la prueba de carga.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/_common.sh"

tf_out() { terraform -chdir="$ROOT/terraform" output -raw "$1"; }
CLUSTER=$(tf_out redshift_cluster)
DB=$(tf_out redshift_database)
SECRET=$(tf_out redshift_secret_arn)
OUT_DIR="$ROOT/docs/evidencias"
mkdir -p "$OUT_DIR"

# Marcador único por corrida: hace que la consulta no coincida con cachés de corridas
# anteriores y permite encontrarla en SYS_QUERY_HISTORY.
RUN_ID="lab5cache_$(date -u +%Y%m%d%H%M%S)"
Q="SELECT '${RUN_ID}' AS marker, event_type, device_id, COUNT(*) AS eventos, AVG(value) AS promedio, MAX(DATEDIFF(ms, event_ts, ingested_at)) AS max_latencia_ms FROM public.events GROUP BY event_type, device_id ORDER BY eventos DESC LIMIT 20"

common=(--cluster-identifier "$CLUSTER" --database "$DB" --secret-arn "$SECRET" --no-cli-pager --query Id --output text)

echo "Corrida: ${RUN_ID}"
echo "Se harán ~12 llamadas a la Redshift Data API."
confirm "¿Ejecutar la comparación de caché?"

to_ms() { python3 -c "import sys; print(f'{int(sys.argv[1])/1e6:.1f}')" "$1"; }

echo "== 1/3 Caché DESHABILITADA (consulta fría) =="
id1=$(aws redshift-data batch-execute-statement "${common[@]}" --statement-name lab5-cache-off \
  --sqls "SET enable_result_cache_for_session TO off" "$Q")
wait_statement "$id1"; d1=$(to_ms "$STMT_DURATION_NS")
echo "  duración: ${d1} ms"

echo "== 2/3 Caché habilitada, primera ejecución (llena la caché) =="
id2=$(aws redshift-data execute-statement "${common[@]}" --statement-name lab5-cache-fill --sql "$Q")
wait_statement "$id2"; d2=$(to_ms "$STMT_DURATION_NS")
echo "  duración: ${d2} ms"

echo "== 3/3 Caché CARGADA (misma consulta) =="
id3=$(aws redshift-data execute-statement "${common[@]}" --statement-name lab5-cache-hit --sql "$Q")
wait_statement "$id3"; d3=$(to_ms "$STMT_DURATION_NS")
echo "  duración: ${d3} ms"

echo "== Confirmación en SYS_QUERY_HISTORY =="
HQ="SELECT query_id, result_cache_hit, elapsed_time/1000.0 AS elapsed_ms, execution_time/1000.0 AS exec_ms FROM sys_query_history WHERE query_text LIKE '%${RUN_ID}%' AND query_text NOT LIKE '%sys_query_history%' AND query_type = 'SELECT' ORDER BY start_time"
id4=$(aws redshift-data execute-statement "${common[@]}" --statement-name lab5-cache-history --sql "$HQ")
wait_statement "$id4"
hist=$(aws redshift-data get-statement-result --id "$id4" --no-cli-pager --output json)

# Resumen legible + JSON para el reporte (docs/build_report.py lo lee).
python3 - "$d1" "$d2" "$d3" "$RUN_ID" "$hist" "$OUT_DIR/cache_test.json" <<'PY'
import json, sys
d1, d2, d3 = (float(x) for x in sys.argv[1:4])
run_id, hist_raw, out_path = sys.argv[4], sys.argv[5], sys.argv[6]

def cell(c):
    return next(iter(c.values())) if c else None

hist = [[cell(c) for c in row] for row in json.loads(hist_raw).get("Records", [])]
data = {
    "run_id": run_id,
    "sin_cache_ms": d1,
    "primera_con_cache_ms": d2,
    "cache_cargada_ms": d3,
    "mejora_x": round(d1 / d3, 1) if d3 else None,
    "reduccion_pct": round((1 - d3 / d1) * 100, 1) if d1 else None,
    "historial": [
        {"query_id": r[0], "result_cache_hit": r[1], "elapsed_ms": r[2], "exec_ms": r[3]} for r in hist
    ],
}
with open(out_path, "w") as fh:
    json.dump(data, fh, indent=2)

print("\n===== Resultado caché de resultados de Redshift =====")
print(f"{'Escenario':<38}{'Duración (Data API)':>20}")
print(f"{'1. Caché deshabilitada (fría)':<38}{d1:>17.1f} ms")
print(f"{'2. Primera ejecución (llena caché)':<38}{d2:>17.1f} ms")
print(f"{'3. Caché cargada':<38}{d3:>17.1f} ms")
if data["mejora_x"]:
    print(f"\nMejora: {data['mejora_x']}x más rápido ({data['reduccion_pct']}% menos tiempo)")
print("\nSYS_QUERY_HISTORY (query_id, result_cache_hit, elapsed_ms, exec_ms):")
for r in hist:
    print("  ", r)
print(f"\nGuardado en {out_path}")
PY
