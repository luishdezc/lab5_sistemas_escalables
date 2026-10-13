"""Pruebas locales de la Lambda consumidora con eventos de Kinesis simulados.

No llaman a AWS: el cliente de redshift-data se reemplaza por un doble en memoria.
Ejecutar desde lab5-streaming/:  python3 -m unittest discover -s lambda/consumer/tests -v
"""

import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import handler  # noqa: E402


def kinesis_record(payload, seq):
    """Construye un registro con la misma forma que entrega el event source mapping."""
    raw = payload if isinstance(payload, (bytes, str)) else json.dumps(payload)
    if isinstance(raw, str):
        raw = raw.encode()
    return {
        "eventSource": "aws:kinesis",
        "eventID": f"shardId-000000000000:{seq}",
        "kinesis": {
            "partitionKey": "dev-1",
            "sequenceNumber": str(seq),
            "data": base64.b64encode(raw).decode(),
        },
    }


def event(n=3, start=1000):
    return {
        "Records": [
            kinesis_record(
                {
                    "event_id": f"evt-{i}",
                    "device_id": f"dev-{i % 5}",
                    "event_type": "temperature",
                    "value": 20.5 + i,
                    "event_ts": "2026-10-13T18:00:00.123Z",
                },
                start + i,
            )
            for i in range(n)
        ]
    }


class FakeClient:
    """Doble de redshift-data que registra las llamadas."""

    def __init__(self, fail=False):
        self.calls = []
        self.fail = fail

    def execute_statement(self, **kwargs):
        self.calls.append(("execute_statement", kwargs))
        if self.fail:
            raise RuntimeError("ThrottlingException simulada")
        return {"Id": "stmt-123"}

    def batch_execute_statement(self, **kwargs):
        self.calls.append(("batch_execute_statement", kwargs))
        if self.fail:
            raise RuntimeError("ThrottlingException simulada")
        return {"Id": "stmt-batch-1"}


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()
        handler._client = self.client

    def tearDown(self):
        handler._client = None

    def test_un_solo_insert_multifila_por_lote(self):
        resp = handler.handler(event(50), None)
        self.assertEqual(resp, {"batchItemFailures": []})
        self.assertEqual(len(self.client.calls), 1)
        name, kwargs = self.client.calls[0]
        self.assertEqual(name, "execute_statement")
        self.assertIn("ClusterIdentifier", kwargs)
        self.assertNotIn("WorkgroupName", kwargs)
        sql = kwargs["Sql"]
        self.assertTrue(sql.startswith("INSERT INTO public.events"))
        self.assertEqual(sql.count("::TIMESTAMP)"), 50)
        self.assertIn("'2026-10-13 18:00:00.123000'::TIMESTAMP", sql)

    def test_lote_grande_usa_una_sola_llamada_batch(self):
        rows = [handler.parse_record(r) for r in event(500)["Records"]]
        statements = handler.build_statements(rows, max_bytes=5_000)
        self.assertGreater(len(statements), 1)
        self.assertEqual(sum(s.count("::TIMESTAMP)") for s in statements), 500)
        self.assertTrue(all(len(s.encode()) <= 5_000 for s in statements))

        # Forzamos un límite pequeño para simular SQL que no cabe en una sentencia.
        original = handler.MAX_SQL_BYTES
        handler.MAX_SQL_BYTES = 20_000
        try:
            resp = handler.handler(event(500), None)
        finally:
            handler.MAX_SQL_BYTES = original
        self.assertEqual(resp, {"batchItemFailures": []})
        self.assertEqual(len(self.client.calls), 1)
        self.assertEqual(self.client.calls[0][0], "batch_execute_statement")

    def test_500_registros_caben_en_limite_real(self):
        rows = [handler.parse_record(r) for r in event(500)["Records"]]
        statements = handler.build_statements(rows)
        self.assertLessEqual(len(statements), handler.MAX_SQLS_PER_CALL)

    def test_registros_invalidos_se_descartan(self):
        ev = event(2)
        ev["Records"].append(kinesis_record(b"esto no es json", 9001))
        ev["Records"].append(kinesis_record({"device_id": "x'; DROP TABLE events;--",
                                             "event_type": "t", "value": 1,
                                             "event_ts": "2026-10-13T18:00:00Z"}, 9002))
        ev["Records"].append(kinesis_record({"device_id": "d", "event_type": "t",
                                             "value": "NaN", "event_ts": "2026-10-13T18:00:00Z"}, 9003))
        ev["Records"].append(kinesis_record({"device_id": "d", "event_type": "t",
                                             "value": True, "event_ts": "2026-10-13T18:00:00Z"}, 9004))
        resp = handler.handler(ev, None)
        self.assertEqual(resp, {"batchItemFailures": []})
        sql = self.client.calls[0][1]["Sql"]
        self.assertEqual(sql.count("::TIMESTAMP)"), 2)
        self.assertNotIn("DROP", sql)

    def test_lote_todo_invalido_no_llama_a_aws(self):
        ev = {"Records": [kinesis_record(b"{}", 1)]}
        self.assertEqual(handler.handler(ev, None), {"batchItemFailures": []})
        self.assertEqual(self.client.calls, [])

    def test_lote_vacio(self):
        self.assertEqual(handler.handler({"Records": []}, None), {"batchItemFailures": []})
        self.assertEqual(self.client.calls, [])

    def test_fallo_de_data_api_reporta_primer_registro(self):
        handler._client = FakeClient(fail=True)
        resp = handler.handler(event(3, start=7000), None)
        self.assertEqual(resp, {"batchItemFailures": [{"itemIdentifier": "7000"}]})
        self.assertEqual(len(handler._client.calls), 1)  # sin reintentos en la Lambda

    def test_event_id_opcional_usa_sequence_number(self):
        rec = kinesis_record({"device_id": "d1", "event_type": "t", "value": 3,
                              "event_ts": "2026-10-13T18:00:00Z"}, 4242)
        self.assertEqual(handler.parse_record(rec)[0], "4242")

    def test_zona_horaria_se_convierte_a_utc(self):
        self.assertEqual(handler.parse_timestamp("2026-10-13T13:00:00-05:00"),
                         "2026-10-13 18:00:00.000000")
        self.assertEqual(handler.parse_timestamp("2026-10-13T18:00:00"),
                         "2026-10-13 18:00:00.000000")
        with self.assertRaises(ValueError):
            handler.parse_timestamp("13/10/2026")

    def test_escapado_sql(self):
        self.assertEqual(handler.sql_str("o'brien\\x"), "'o''brien\\\\x'")


if __name__ == "__main__":
    unittest.main()
