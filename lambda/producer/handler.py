"""Lambda productora (solo en api_integration_mode = "lambda").

API Gateway (proxy, body ya validado por JSON schema) -> Kinesis PutRecord.
Se usa cuando LabRole no puede ser asumido por apigateway.amazonaws.com.
"""

import base64
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

STREAM_NAME = os.environ.get("STREAM_NAME", "")

_client = None


def _get_client():
    global _client
    if _client is None:
        import boto3
        from botocore.config import Config

        # Sin reintentos en cadena: si Kinesis rechaza, el cliente recibe 502 y decide.
        _client = boto3.client(
            "kinesis",
            config=Config(retries={"total_max_attempts": 1, "mode": "standard"}),
        )
    return _client


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        payload = json.loads(body)
        partition_key = payload["device_id"]
    except (ValueError, KeyError, TypeError):
        return _response(400, {"message": "body invalido"})

    try:
        resp = _get_client().put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(payload, separators=(",", ":")).encode(),
            PartitionKey=partition_key,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("PutRecord falló: %s", exc)
        return _response(502, {"status": "error", "type": type(exc).__name__})

    return _response(200, {
        "status": "accepted",
        "sequence_number": resp["SequenceNumber"],
        "shard_id": resp["ShardId"],
    })
