# Guía de demo EP2 — RabbitMQ (VidaSalud)

## 1. Clúster de 2 nodos
`docker compose up -d rabbit1 rabbit2` → `docker exec rabbit1 rabbitmqctl cluster_status` debe listar `rabbit@rabbit1` y `rabbit@rabbit2`. Consola: `http://<host>:15672` (usuario/clave de `.env`).

## 2. Topología (se declara al arrancar los servicios, ver `RabbitTopologyConfig`)
| Elemento | Tipo | Detalle |
|---|---|---|
| `vidasalud.atenciones.direct` | direct | RK `atencion.confirmar` → `q.atenciones.confirmar` |
| `vidasalud.eventos.topic` | topic | RK `atencion.confirmada/rechazada/estado`; `atencion.*` → `q.notificaciones`; `#` → `q.auditoria` |
| `vidasalud.dlx.direct` | direct | cada cola → su `*.dlq` |
Colas quorum con TTL, `x-max-length` y `overflow=drop-head` (política de retención).

## 3. Flujo feliz
1. Paciente: `POST /api/appointments` → `SOLICITADA` (evento `atencion.estado`).
2. Recepcionista: `PUT /api/appointments/{id}/estado {"estado":"CONFIRMADA"}` → 202; comando a `q.atenciones.confirmar`.
3. Catálogo consume (ACK manual), descuenta cupo del box de forma idempotente y publica `atencion.confirmada` (o `atencion.rechazada` si no hay cupo).
4. Auditoría aplica el estado; Notificación registra el aviso.
Verificar en la consola: mensajes entrando/saliendo, 0 en las DLQ.

## 4. Flujo de error → DLQ
- Prestación inexistente (error no recuperable): crear una atención con `prestacionId` que no existe en catálogo y confirmarla → NACK sin requeue → mensaje en `q.atenciones.confirmar.dlq`; el `DlqListener` lo registra en el log (`docker logs ms-vidasalud-catalog`).
- Error recuperable (p. ej. detener `db-catalog` un momento): el listener republica con cabecera `x-app-retries` hasta 3 veces y luego va a DLQ.

## 5. Administración (Admin)
`POST /api/admin/rabbit/queues {"name":"q.demo"}`, `GET /queues/q.demo`, `DELETE /queues/q.demo/messages` (purgar), `POST /exchanges`, `POST /bindings`. Con rol distinto de Admin → 403; nombres inválidos → 400; duplicados → 409.

## 6. Métricas a explicar (consola → Overview/Queues)
Messages ready / unacked (acumulación), publish/deliver/ack rates (throughput), consumers (capacidad), memoria y file descriptors del nodo, mensajes en DLQ (fallos). Retención: TTL + max-length evitan crecimiento ilimitado de colas.

## 7. Repositorios
Un repo por componente (`frontend-vidasalud`, `ms-vidasalud-bff`, `ms-vidasalud-appointments`, `ms-vidasalud-catalog`, `ms-vidasalud-notification`, `ms-vidasalud-rabbit-admin`, y uno de infraestructura con `compose.yaml`), cada uno con `.gitignore` y `README`.
