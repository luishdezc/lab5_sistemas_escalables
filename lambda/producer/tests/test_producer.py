"""Pruebas locales de la Lambda productora (sin AWS: cliente Kinesis simulado)."""

import importlib.util
import json
import os
import unittest

# Se carga con otro nombre para no chocar con el handler de la consumidora.
_spec = importlib.util.spec_from_file_location(
    "producer_handler", os.path.join(os.path.dirname(__file__), "..", "handler.py")
)
producer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(producer)


class FakeKinesis:
    def __init__(self, fail=False):
        self.calls, self.fail = [], fail

    def put_record(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise RuntimeError("ProvisionedThroughputExceededException")
        return {"SequenceNumber": "123", "ShardId": "shardId-000000000000"}


class ProducerTests(unittest.TestCase):
    def tearDown(self):
        producer._client = None

    def test_put_record_con_partition_key_device_id(self):
        producer._client = FakeKinesis()
        body = {"device_id": "dev-7", "event_type": "t", "value": 1, "event_ts": "2026-10-13T18:00:00Z"}
        resp = producer.handler({"body": json.dumps(body)}, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(producer._client.calls[0]["PartitionKey"], "dev-7")
        self.assertEqual(json.loads(producer._client.calls[0]["Data"]), body)

    def test_error_de_kinesis_devuelve_502_sin_reintentar(self):
        producer._client = FakeKinesis(fail=True)
        resp = producer.handler({"body": json.dumps({"device_id": "d"})}, None)
        self.assertEqual(resp["statusCode"], 502)
        self.assertEqual(len(producer._client.calls), 1)

    def test_body_invalido(self):
        producer._client = FakeKinesis()
        self.assertEqual(producer.handler({"body": "no-json"}, None)["statusCode"], 400)
        self.assertEqual(producer._client.calls, [])


if __name__ == "__main__":
    unittest.main()
