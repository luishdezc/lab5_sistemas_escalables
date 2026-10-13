#!/usr/bin/env python3
"""Prueba de carga CONTROLADA contra POST /events.

No es un stress test: demuestra que el pipeline atiende peticiones concurrentes con
límites estrictos para no saturar la cuenta del Learner Lab.

- Por defecto: 300 eventos, concurrencia 10, 15 req/s (por debajo del throttling de 20 rps).
- Topes duros en código: máx. 1000 eventos y 20 de concurrencia aunque se pida más.
- Sin reintentos: 429 y 5xx solo se cuentan.
- Pide confirmación "s/n" antes de enviar.

Uso:
  python3 scripts/load_test.py --url "$(terraform -chdir=terraform output -raw api_endpoint)"
  python3 scripts/load_test.py --url ... --dry-run     # solo muestra el resumen
Requiere: pip install aiohttp
"""

import argparse
import asyncio
import random
import statistics
import sys
import time
import uuid
from collections import Counter
from datetime import datetime, timezone

# Topes duros: no se pueden superar desde la CLI.
HARD_MAX_EVENTS = 1000
HARD_MAX_CONCURRENCY = 20
# La tasa nunca supera el rate_limit del stage (20 rps) para no provocar 429 a propósito.
HARD_MAX_RATE = 19.0

EVENT_TYPES = ["temperature", "humidity", "pressure", "vibration"]
DEVICES = [f"dev-{i:03d}" for i in range(1, 51)]


def make_event():
    """Evento sintético que cumple el JSON schema de API Gateway."""
    etype = random.choice(EVENT_TYPES)
    base = {"temperature": 22, "humidity": 55, "pressure": 1013, "vibration": 0.5}[etype]
    return {
        "event_id": uuid.uuid4().hex,
        "device_id": random.choice(DEVICES),
        "event_type": etype,
        "value": round(base + random.uniform(-5, 5), 3),
        "event_ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    }


def percentile(sorted_values, p):
    """Percentil por interpolación lineal (valores ya ordenados)."""
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


class RateLimiter:
    """Espacia los inicios de request a 1/rate segundos (sin ráfagas)."""

    def __init__(self, rate):
        self.interval = 1.0 / rate
        self.next_slot = time.monotonic()
        self.lock = asyncio.Lock()

    async def wait(self):
        async with self.lock:
            now = time.monotonic()
            if self.next_slot > now:
                await asyncio.sleep(self.next_slot - now)
            self.next_slot = max(self.next_slot, now) + self.interval


async def send_one(session, url, limiter, sem, results):
    await limiter.wait()
    async with sem:
        started = time.perf_counter()
        try:
            async with session.post(url, json=make_event()) as resp:
                await resp.read()
                status = resp.status
        except Exception as exc:  # noqa: BLE001 - errores de red se cuentan, no se reintentan
            status = f"error:{type(exc).__name__}"
        results.append((status, time.perf_counter() - started))


async def run(url, total, concurrency, rate, timeout):
    import aiohttp  # import diferido para que --dry-run funcione sin aiohttp

    limiter = RateLimiter(rate)
    sem = asyncio.Semaphore(concurrency)
    results = []
    client_timeout = aiohttp.ClientTimeout(total=timeout)
    connector = aiohttp.TCPConnector(limit=concurrency)
    started = time.perf_counter()
    async with aiohttp.ClientSession(timeout=client_timeout, connector=connector) as session:
        await asyncio.gather(*(send_one(session, url, limiter, sem, results) for _ in range(total)))
    return results, time.perf_counter() - started


def report(results, elapsed):
    codes = Counter(status for status, _ in results)
    ok = codes.get(200, 0)
    latencies = sorted(lat * 1000 for status, lat in results if status == 200)
    print("\n===== Resultados =====")
    print(f"Enviados:    {len(results)}")
    print(f"Éxitos:      {ok}")
    print(f"Errores:     {len(results) - ok}")
    for status, count in sorted(codes.items(), key=lambda kv: str(kv[0])):
        if status != 200:
            print(f"  código {status}: {count}")
    if latencies:
        print(f"Latencia p50: {percentile(latencies, 50):.1f} ms")
        print(f"Latencia p95: {percentile(latencies, 95):.1f} ms")
        print(f"Latencia p99: {percentile(latencies, 99):.1f} ms")
        print(f"Latencia media: {statistics.mean(latencies):.1f} ms")
    print(f"Duración:    {elapsed:.1f} s")
    print(f"Throughput:  {len(results) / elapsed:.2f} req/s ({ok / elapsed:.2f} éxitos/s)")


def main():
    parser = argparse.ArgumentParser(description="Prueba de carga controlada del lab5")
    parser.add_argument("--url", required=True, help="URL completa de POST /events")
    parser.add_argument("--events", type=int, default=300, help=f"total de eventos (tope {HARD_MAX_EVENTS})")
    parser.add_argument("--concurrency", type=int, default=10, help=f"concurrencia (tope {HARD_MAX_CONCURRENCY})")
    parser.add_argument("--rate", type=float, default=15.0, help=f"requests/segundo (tope {HARD_MAX_RATE})")
    parser.add_argument("--timeout", type=float, default=10.0, help="timeout por request en s")
    parser.add_argument("--yes", action="store_true", help="no pedir confirmación")
    parser.add_argument("--dry-run", action="store_true", help="mostrar resumen y un evento de ejemplo, sin enviar")
    args = parser.parse_args()

    # Aplicar topes duros sin excepción.
    total = max(1, min(args.events, HARD_MAX_EVENTS))
    concurrency = max(1, min(args.concurrency, HARD_MAX_CONCURRENCY))
    rate = max(0.1, min(args.rate, HARD_MAX_RATE))
    for name, asked, used in (("events", args.events, total), ("concurrency", args.concurrency, concurrency),
                              ("rate", args.rate, rate)):
        if asked != used:
            print(f"AVISO: --{name}={asked} ajustado al tope permitido: {used}")

    print("===== Resumen de la prueba =====")
    print(f"Endpoint:          {args.url}")
    print(f"Total de eventos:  {total}")
    print(f"Concurrencia máx.: {concurrency}")
    print(f"Tasa máx.:         {rate:g} req/s")
    print(f"Duración estimada: ~{total / rate:.0f} s")
    print("Reintentos:        ninguno (429/5xx solo se cuentan)")

    if args.dry_run:
        print("\nEvento de ejemplo:", make_event())
        return 0
    if not args.yes:
        if input("\n¿Enviar? [s/n]: ").strip().lower() != "s":
            print("Cancelado.")
            return 1

    results, elapsed = asyncio.run(run(args.url, total, concurrency, rate, args.timeout))
    report(results, elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
