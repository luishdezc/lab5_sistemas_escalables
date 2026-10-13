# Lab 5 — Servicio de streaming en AWS con Terraform

Ingesta de eventos → procesamiento por lotes → almacenamiento columnar → visualización.

```
Cliente ──POST /events──▶ API Gateway (REST, JSON schema, throttling 20/40)
                              │  integración directa PutRecord (o Lambda productora)
                              ▼
                     Kinesis Data Streams (ON_DEMAND, partition key = device_id)
                              │  event source mapping: lotes de hasta 500 / 10 s
                              ▼
                     Lambda consumidora (Python 3.12, concurrencia reservada 2)
                              │  1 INSERT multi-fila por lote vía Redshift Data API
                              ▼                     └─ lotes fallidos ─▶ SQS (DLQ)
                     Amazon Redshift provisionado (single-node, tabla public.events)
                              │  Data API
                              ▼
                     Grafana OSS en EC2 (o Amazon Managed Grafana)
```

## Estructura

```
lab5-streaming/
  terraform/   providers, variables, network, kinesis, sqs, lambda, apigateway,
               redshift, grafana, outputs, terraform.tfvars.example, templates/
  lambda/consumer/  handler.py + tests/ (eventos de Kinesis simulados)
  lambda/producer/  handler.py + tests/ (solo si api_integration_mode = "lambda")
  grafana/     provisioning del data source y dashboard JSON
  scripts/     deploy.sh, load_test.py, verify.sh, destroy.sh, create_table.sh
```

## Reglas para no saturar la cuenta

Todo el diseño minimiza llamadas a la API de AWS:

| Punto | Medida |
|---|---|
| Terraform | `-parallelism=3`, un solo `plan -out=tfplan` y `apply tfplan` (sin refresh extra), `max_retries = 2` en el provider |
| Preflight | solo `sts get-caller-identity` e `iam get-role LabRole` |
| Lambda consumidora | 1 llamada a la Data API por lote, sin polling del resultado, concurrencia reservada 2, 1 reintento del SDK |
| Event source mapping | `batch_size=500`, ventana 10 s, `parallelization_factor=1`, 2 reintentos, bisect, DLQ |
| Scripts | espera con backoff 5→10→20→30 s, máx. 10 consultas; nunca reintentos en cadena |
| Grafana | refresh 5 min (mínimo forzado en el servidor con `GF_DASHBOARDS_MIN_REFRESH_INTERVAL=5m`), rango 1 h, 4 consultas agregadas |
| Prueba de carga | 300 eventos, 10 de concurrencia, 15 rps; topes duros 1000 / 20 / 19 rps |

## Despliegue

```bash
cd lab5-streaming
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # pon tu IP en my_ip_cidr
./scripts/deploy.sh        # tests locales, fmt, validate, preflight, plan y apply (cada paso pide s/n)
```

`api_integration_mode`: `direct` si `apigateway.amazonaws.com` aparece en la trust policy de
LabRole (lo muestra el preflight); si no, `lambda` y se crea una Lambda productora.

### Prueba manual (un solo curl)

```bash
URL=$(terraform -chdir=terraform output -raw api_endpoint)
curl -s -X POST "$URL" -H 'Content-Type: application/json' -d '{
  "event_id": "manual-0001", "device_id": "dev-001", "event_type": "temperature",
  "value": 23.4, "event_ts": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'
# => {"status": "accepted", "sequence_number": "...", "shard_id": "..."}
```

Un body inválido devuelve `400` con el detalle de validación (no llega a Kinesis).

### Prueba de carga controlada y verificación

```bash
pip install aiohttp
python3 scripts/load_test.py --url "$URL"     # muestra el resumen y pide s/n
./scripts/verify.sh                           # espera 60 s, 1 COUNT(*) en Redshift, 1 consulta a la DLQ
```

### Grafana

```bash
terraform -chdir=terraform output grafana_url
terraform -chdir=terraform output -raw grafana_admin_password   # usuario: admin
```

La instalación tarda ~3 min tras el apply. El dashboard **Lab5 → Lab5 - Streaming de eventos** tiene:
eventos por minuto, promedio de `value` por `event_type`, top 10 `device_id` y latencia promedio
de ingesta (`ingested_at - event_ts`, incluye la ventana de batching de 10 s).

**Por qué Grafana OSS en EC2 y no Managed Grafana:** Amazon Managed Grafana solo permite iniciar
sesión con IAM Identity Center o SAML. El Learner Lab no deja habilitar Identity Center y no hay
IdP SAML, así que el workspace se podría crear pero nadie podría entrar. Queda disponible con
`enable_managed_grafana = true` (plan A) y la EC2 t3.micro con `LabInstanceProfile` es el plan B
activo. El puerto 3000 solo está abierto a `my_ip_cidr`.

## Cómo soporta múltiples peticiones concurrentes

La capacidad se sustenta en el **diseño**, no en la prueba:

- **API Gateway** es un servicio gestionado que escala solo; el throttling del stage
  (20 rps / ráfaga 40) es una protección deliberada para el lab y responde 429 en lugar de degradar.
  **En producción estos valores se subirían** (los límites de cuenta por defecto son 10 000 rps)
  y se añadirían API keys/usage plans por cliente.
- **Kinesis ON_DEMAND** absorbe picos ajustando shards automáticamente y desacopla la ingesta
  del procesamiento: si el consumidor va más lento, los datos esperan en el stream (24 h).
- **La Lambda consumidora procesa por lotes** (hasta 500 registros en un único INSERT), así que el
  número de escrituras en Redshift no crece con el número de peticiones. Su concurrencia está
  limitada a propósito; el backlog se acumula en Kinesis, no en el cliente.
- **Redshift** recibe pocas escrituras grandes (no una por petición), así que un solo nodo basta para la
  demo; en producción se escalaría con Redshift Serverless (RPU automáticos), concurrency scaling o elastic resize.

La prueba de carga es una **demostración controlada** (300 eventos a 15 rps con 10 conexiones
concurrentes), no un stress test.

### Resultados

_Completar tras ejecutar `load_test.py` y `verify.sh`._

## Adaptaciones al Learner Lab (descubiertas en el primer apply)

| Error | Causa | Solución |
|---|---|---|
| `kinesis:IncreaseStreamRetentionPeriod ... explicit deny in a service control policy` | El recurso `aws_kinesis_stream` siempre llama a esa acción tras crear el stream, y la SCP del lab la prohíbe | El stream se crea con `aws kinesis create-stream` (ON_DEMAND, 24 h) desde `null_resource.kinesis_stream` / `scripts/kinesis_stream.sh` |
| `redshift-serverless:CreateNamespace ... no identity-based policy allows` | El Learner Lab no habilita Redshift Serverless | Cluster de Redshift provisionado single-node (`redshift_node_type`), misma Data API, tabla y dashboard |
| `CreateCluster: Invalid node type: dc2.large` | La familia DC2 ya no se puede crear | `redshift_node_type = "ra3.large"` (el RA3 más pequeño) |
| `You can't disable automated snapshots for ra3.large` | RA3 exige retención de snapshots de 1 a 35 días | `automated_snapshot_retention_period = 1` |

## Decisiones y limitaciones

- **Kinesis en lugar de MSK**: MSK es caro, tarda ~20 min en aprovisionar y genera muchas llamadas.
- **Data API con secreto (Secrets Manager)**: Terraform, la Lambda y Grafana usan el mismo usuario
  admin vía `SecretArn`, así no hay que gestionar GRANTs para la identidad IAM de LabRole.
- **SQL seguro**: los campos se validan con las mismas regex del JSON schema y además se escapan
  comillas y barras invertidas; `value` debe ser numérico finito. Se usa escapado y no parámetros
  porque la Data API tendría que recibir 2 500 parámetros por lote.
- **Sin polling en la Lambda**: el INSERT es asíncrono; si el SQL falla en Redshift (no al enviarlo)
  el lote no se reintenta. Por eso la tabla se crea antes del event source mapping.
- **At-least-once**: un reintento puede duplicar filas; `verify.sh` muestra `COUNT(DISTINCT event_id)`.
- **La DLQ recibe metadatos** del lote fallido (shard y rango de secuencias), no el payload.
- **Throttling**: con 20 rps sostenidos, una prueba por encima devolvería 429 (contados, no reintentados).
- **Concurrencia reservada**: si la cuenta tiene límite de 10 ejecuciones, reservar 2 falla;
  usa `consumer_reserved_concurrency = -1`.
- El subnet group de Redshift excluye `use1-az3`; las subnets se filtran por AZ ID.
- La contraseña de Grafana viaja en el user_data de la EC2 (aceptable para el lab, no para producción).

## Destruir todo al terminar

```bash
./scripts/destroy.sh     # terraform destroy -parallelism=3
```

El cluster de Redshift, Kinesis ON_DEMAND y la EC2 cobran por hora: **destruye al terminar**.
