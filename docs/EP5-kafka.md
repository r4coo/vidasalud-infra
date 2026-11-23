# EP5 – Apache Kafka en VidaSalud

Kafka **complementa** a RabbitMQ; no lo reemplaza.

| | RabbitMQ | Kafka |
|---|---|---|
| Uso | Comandos y colas de trabajo: confirmar una atención, auditoría, notificaciones (con DLQ) | Registro de eventos en streaming: analítica y alertas en tiempo real, reproducible |
| Mensaje | Se consume y desaparece | Se conserva según retención; cada grupo lee a su ritmo |

## Arquitectura

- 3 × ZooKeeper + 3 × broker (Confluent 7.6.1), red interna `vidasalud-network`. Solo Kafka UI (8090) se publica.
- Replicación 3, `min.insync.replicas=2`, auto-creación de tópicos desactivada: los crea el contenedor `kafka-init`.
- `ms-vidasalud-kafka-admin` (8089): administración por API, detrás del BFF y solo Admin.

## Tópicos (3 particiones, 3 réplicas)

| Tópico | Clave | Política | Por qué |
|---|---|---|---|
| `vidasalud.atenciones.eventos` | id de la atención | `delete`, retención 7 días (604800000 ms) | Historial de ciclo de vida; la clave mantiene el orden de una atención en su partición |
| `vidasalud.catalogo.cupos` | `prestacionId\|fecha\|hora` | `compact` | Solo importa el último valor de cupos por horario: Kafka conserva el último mensaje por clave |

## Flujo

1. Appointments publica cada cambio de estado y el resultado del catálogo (`CONFIRMADA`/`RECHAZADA`) en `atenciones.eventos`.
2. Catalog publica los cupos restantes tras cada reserva en `catalogo.cupos`.
3. Notification consume con dos grupos independientes (`@KafkaListener`):
   - `vidasalud-analitica`: ambos tópicos → métricas en memoria, `GET /api/analytics/resumen`.
   - `vidasalud-alertas`: `atenciones.eventos` → alertas (rechazos, cancelaciones).
4. Si Kafka cae, los productores registran un aviso y el flujo con RabbitMQ sigue funcionando.

## Manejo de errores

- Productor: `acks=all`, idempotencia, reintentos, timeouts acotados (`max.block.ms=3000`).
- Consumidor: JSON validado; mensaje inválido → se registra y se salta sin reintentos; fallo transitorio → 3 reintentos cada 1 s y se salta.
- Offsets confirmados tras procesar cada mensaje (`AckMode.RECORD`); eventos duplicados descartados por `eventId`.

## Levantar el entorno

```bash
# .env: KAFKA_UI_PASSWORD=...  y  COMPOSE_FILE=compose.yaml:compose.kafka.yaml
docker compose up -d --build
docker compose logs kafka-init          # muestra los dos tópicos creados
```

Kafka UI: `http://<host>:8090` (usuario `KAFKA_UI_USER`, clave `KAFKA_UI_PASSWORD`).
Abre el puerto 8090 en el Security Group solo para tu IP y ciérralo al terminar.

## API de administración (vía BFF, token Admin)

`GET /api/admin/kafka/cluster`, `GET|POST /api/admin/kafka/topics`, `GET|DELETE /api/admin/kafka/topics/{n}`,
`PUT /api/admin/kafka/topics/{n}/config`, `PUT /api/admin/kafka/topics/{n}/partitions`,
`GET /api/admin/kafka/groups`, `GET /api/admin/kafka/groups/{g}` (offsets y lag).

## Demo rápida

1. Kafka UI → Topics: los dos tópicos con 3 particiones y réplicas en sincronía.
2. Agendar una atención y confirmarla desde la app.
3. Kafka UI → Messages del tópico: aparecen los eventos con su partición y offset.
4. Kafka UI → Consumers: grupos `vidasalud-analitica` y `vidasalud-alertas`, con su lag en 0.
5. `GET /api/analytics/resumen`: contadores y cupos actualizados.
6. En Kafka UI crear un tópico nuevo (3 particiones, 3 réplicas) para mostrar la administración.
