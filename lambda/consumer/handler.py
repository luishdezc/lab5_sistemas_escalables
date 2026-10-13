"""Lambda consumidora: Kinesis -> Redshift (Data API, cluster provisionado).

Diseño orientado a minimizar llamadas a AWS:
- Cada lote de Kinesis genera UNA sola llamada a la Data API
  (execute_statement, o batch_execute_statement si el SQL no cabe en un solo statement).
- Se usa un INSERT multi-fila; nunca una llamada por registro.
- No se hace polling del resultado: solo se registra el ID del statement.
- Los valores se validan con reglas estrictas y se escapan antes de construir el SQL.
"""

import base64
import json
import logging
import math
import os
import re
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE = os.environ.get("RS_TABLE", "public.events")
CLUSTER = os.environ.get("RS_CLUSTER", "")
DATABASE = os.environ.get("RS_DATABASE", "streaming")
SECRET_ARN = os.environ.get("RS_SECRET_ARN", "")

# La Data API acepta SQL de hasta 100 KB; dejamos margen.
MAX_SQL_BYTES = 90_000
# batch_execute_statement admite como máximo 40 sentencias.
MAX_SQLS_PER_CALL = 40

COLUMNS = "(event_id, device_id, event_type, value, event_ts)"

# Mismas reglas que el JSON schema de API Gateway (defensa en profundidad).
ID_RE = re.compile(r"^[A-Za-z0-9_.:\-]{1,64}$")
TYPE_RE = re.compile(r"^[A-Za-z0-9_\-]{1,32}$")
TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})?$"
)

_client = None


def _get_client():
    """Crea el cliente de redshift-data una sola vez por contenedor."""
    global _client
    if _client is None:
        import boto3  # import diferido: los tests locales no necesitan boto3
        from botocore.config import Config

        # Un solo reintento del SDK: los reintentos los gestiona el event source mapping.
        _client = boto3.client(
            "redshift-data",
            config=Config(retries={"total_max_attempts": 2, "mode": "standard"}),
        )
    return _client


def parse_timestamp(raw):
    """Convierte ISO 8601 a texto 'YYYY-MM-DD HH:MM:SS.ffffff' en UTC."""
    if not isinstance(raw, str):
        raise ValueError("event_ts debe ser string")
    m = TS_RE.match(raw)
    if not m:
        raise ValueError("event_ts no es ISO 8601")
    date_part, time_part, frac, tz = m.groups()
    frac = (frac or ".0")[1:].ljust(6, "0")
    tz = "+00:00" if tz in (None, "Z") else tz
    # fromisoformat de Python 3.10 no acepta 'Z' ni fracciones variables; normalizamos.
    dt = datetime.fromisoformat(f"{date_part}T{time_part}.{frac}{tz}")
    dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt.strftime("%Y-%m-%d %H:%M:%S.%f")


def parse_record(record):
    """Decodifica y valida un registro de Kinesis. Devuelve una tupla de columnas."""
    kin = record["kinesis"]
    payload = json.loads(base64.b64decode(kin["data"]))
    if not isinstance(payload, dict):
        raise ValueError("payload no es un objeto JSON")

    # Si el cliente no manda event_id usamos el número de secuencia (único en el stream).
    event_id = payload.get("event_id") or kin["sequenceNumber"][-64:]
    device_id = payload.get("device_id")
    event_type = payload.get("event_type")
    value = payload.get("value")

    if not isinstance(event_id, str) or not ID_RE.match(event_id):
        raise ValueError("event_id inválido")
    if not isinstance(device_id, str) or not ID_RE.match(device_id):
        raise ValueError("device_id inválido")
    if not isinstance(event_type, str) or not TYPE_RE.match(event_type):
        raise ValueError("event_type inválido")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("value debe ser numérico")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError("value no es finito")

    return (event_id, device_id, event_type, value, parse_timestamp(payload.get("event_ts")))


def sql_str(text):
    """Literal SQL seguro: duplica comillas simples y barras invertidas.

    Los campos ya pasaron por regex que excluyen comillas y barras, así que esto es
    una segunda barrera por si cambian las reglas de validación.
    """
    return "'" + text.replace("\\", "\\\\").replace("'", "''") + "'"


def row_sql(row):
    event_id, device_id, event_type, value, event_ts = row
    return (
        f"({sql_str(event_id)}, {sql_str(device_id)}, {sql_str(event_type)}, "
        f"{value!r}, {sql_str(event_ts)}::TIMESTAMP)"
    )


def build_statements(rows, max_bytes=MAX_SQL_BYTES):
    """Agrupa filas en el mínimo número de INSERT multi-fila que caben en max_bytes."""
    prefix = f"INSERT INTO {TABLE} {COLUMNS} VALUES "
    statements, current, size = [], [], len(prefix)
    for row in rows:
        values = row_sql(row)
        extra = len(values.encode()) + 2  # ", " separador
        if current and size + extra > max_bytes:
            statements.append(prefix + ", ".join(current))
            current, size = [], len(prefix)
        current.append(values)
        size += extra
    if current:
        statements.append(prefix + ", ".join(current))
    return statements


def handler(event, context):
    records = event.get("Records", [])
    rows, invalid = [], 0

    for rec in records:
        try:
            rows.append(parse_record(rec))
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
            # Un registro malformado no se arregla reintentando: se descarta y se registra.
            invalid += 1
            logger.warning(
                "registro descartado seq=%s motivo=%s",
                rec.get("kinesis", {}).get("sequenceNumber"),
                exc,
            )

    if not rows:
        logger.info("lote sin filas válidas: recibidos=%d invalidos=%d", len(records), invalid)
        return {"batchItemFailures": []}

    statements = build_statements(rows, MAX_SQL_BYTES)
    if len(statements) > MAX_SQLS_PER_CALL:
        # No debería ocurrir con batch_size=500; se reporta para que el ESM divida el lote.
        logger.error("demasiadas sentencias (%d) para una llamada", len(statements))
        return {"batchItemFailures": [{"itemIdentifier": records[0]["kinesis"]["sequenceNumber"]}]}

    common = {"ClusterIdentifier": CLUSTER, "Database": DATABASE, "SecretArn": SECRET_ARN}
    try:
        client = _get_client()
        if len(statements) == 1:
            resp = client.execute_statement(Sql=statements[0], StatementName="lab5-insert", **common)
        else:
            resp = client.batch_execute_statement(Sqls=statements, StatementName="lab5-insert", **common)
    except Exception:  # noqa: BLE001 - cualquier fallo de la llamada reintenta el lote
        logger.exception("fallo al enviar el lote a la Data API")
        # Reportar el primer registro como fallido = reintentar el lote completo desde ahí
        # (el ESM aplica maximum_retry_attempts y bisect; al agotar, va a la DLQ).
        return {"batchItemFailures": [{"itemIdentifier": records[0]["kinesis"]["sequenceNumber"]}]}

    logger.info(
        "lote enviado statement_id=%s filas=%d invalidos=%d sentencias=%d",
        resp.get("Id"),
        len(rows),
        invalid,
        len(statements),
    )
    return {"batchItemFailures": []}
