# vidasalud-infra — Telemedicina VidaSalud

Caso 1 **VidaSalud**: el paciente solicita una atención, recepción la confirma (reserva de cupo asíncrona vía **RabbitMQ**), el resultado queda registrado como **eventos en streaming en Apache Kafka** (analítica y alertas en tiempo real) y la atención se realiza por videollamada.

Este repositorio es la **infraestructura**: `compose.yaml` (servicios, bases, RabbitMQ), `compose.kafka.yaml` (Kafka), Caddy, scripts de despliegue, alta disponibilidad y documentación.

## Evaluaciones que cubre
| Evaluación | Contenido | Dónde |
|---|---|---|
| EP1 | Seguridad: Entra ID (OIDC), API Gateway con JWT authorizer, BFF con roles | este README, `docs/DESPLIEGUE-AWS-AZURE.md` |
| EP2 | RabbitMQ en clúster, colas quorum, DLQ, administración | sección *Mensajería RabbitMQ*, `docs/EP2-guia-demo.md` |
| EP3 / EP5 | Kafka: 3 ZooKeeper + 3 brokers, tópicos, productores/consumidores, administración | sección *Streaming con Kafka*, `docs/EP5-kafka.md` |
| Disponibilidad | Dos instancias EC2 (activa y en espera) | `docs/HA-activo-pasivo.md` |

## Repositorios
Todos bajo la cuenta GitHub `r4coo`.

| Repositorio | Rol | Puerto |
|---|---|---|
| `frontend-vidasalud` | Angular 18 + MSAL (login Entra ID). Se publica en Vercel (y también en EC2 vía Caddy) | 80/443 · 3000 |
| `ms-vidasalud-bff` | BFF: valida JWT de Entra ID y roles, enruta a los servicios | 8084 |
| `ms-vidasalud-appointments` | Principal: atenciones, estados, auditoría (PostgreSQL). Publica a RabbitMQ y Kafka | 8082 |
| `ms-vidasalud-catalog` | Catálogo: prestaciones, boxes, cupos. Consume `q.atenciones.confirmar`; publica cupos a Kafka | 8087 |
| `ms-vidasalud-notification` | Consume `q.notificaciones` (RabbitMQ) y los dos tópicos de Kafka (analítica y alertas) | 8085 |
| `ms-vidasalud-rabbit-admin` | Administración de colas/exchanges/bindings (REST, solo Admin) | 8088 |
| `ms-vidasalud-kafka-admin` | Administración de Kafka: tópicos, parámetros, grupos y lag (REST, solo Admin) | 8089 |
| `vidasalud-infra` (este) | Compose, Caddy, RabbitMQ, Kafka, scripts y docs | |

## Arquitectura
```
Navegador (Angular + MSAL) ──login──► Microsoft Entra ID (Azure)
   │  Vercel (HTTPS)  /  Caddy en EC2                │ access token JWT (claim roles)
   ▼                                                  ▼
AWS API Gateway (HTTP API + JWT authorizer) ──► EC2 · ms-vidasalud-bff :8084 (revalida JWT y rol)
                                                   │
        ┌──────────────┬───────────────┬───────────┴──────┬──────────────────┐
   appointments     catalog       notification       rabbit-admin       kafka-admin
        │               │         │          │             │                  │
        │               │         │          │             ▼                  ▼
        │               │         │          │        RabbitMQ           Kafka (AdminClient)
        ▼               ▼         ▼          ▼
   PostgreSQL ×3   ┌─────────────────┐   ┌──────────────────────────────────────┐
                   │ RabbitMQ        │   │ Kafka                                │
                   │ rabbit1+rabbit2 │   │ 3 ZooKeeper + kafka1/2/3 + Kafka UI  │
                   │ quorum + DLQ    │   │ 2 tópicos · 3 particiones · RF 3     │
                   └─────────────────┘   └──────────────────────────────────────┘
```

**Quién habla con quién**
- **Comandos (RabbitMQ):** appointments → `q.atenciones.confirmar` → catalog (descuenta cupo) → `atencion.confirmada/rechazada` → appointments y notification.
- **Eventos (Kafka):** appointments publica `vidasalud.atenciones.eventos`; catalog publica `vidasalud.catalogo.cupos`; notification los consume con dos grupos (`vidasalud-analitica`, `vidasalud-alertas`).
- Si Kafka falla, los productores registran un aviso y el flujo de RabbitMQ **no se interrumpe**.

Roles (App roles de Entra ID): **Admin**, **Recepcionista**, **Paciente**.

## Mensajería RabbitMQ (EP2)
- Clúster de 2 nodos (`rabbit1`, `rabbit2`).
- Exchanges: `vidasalud.atenciones.direct` (comandos), `vidasalud.eventos.topic` (eventos), `vidasalud.dlx.direct` (DLX).
- Colas quorum: `q.atenciones.confirmar`, `q.notificaciones`, `q.auditoria`, cada una con su `.dlq`.
- ACK manual; error recuperable → hasta 3 reintentos; no recuperable → NACK sin requeue → DLQ con listener que registra el mensaje (`DLQ_LISTENER_ENABLED=false` deja los mensajes visibles en la consola 15672 para la demo).
- Retención: TTL y `x-max-length` con `overflow=drop-head`.
- Administración por API (`ms-vidasalud-rabbit-admin`) y desde la pantalla *Administración RabbitMQ* del front (solo Admin).

## Streaming con Kafka (EP3 / EP5)
Kafka **complementa** a RabbitMQ: RabbitMQ mueve comandos que se consumen y desaparecen; Kafka conserva el historial de eventos y cada grupo de consumidores lo lee a su ritmo.

| Elemento | Detalle |
|---|---|
| Clúster | 3 × ZooKeeper + 3 × broker (Confluent 7.6.1), red interna; solo Kafka UI (8090) se publica |
| Replicación | factor 3, `min.insync.replicas=2`, productor `acks=all` e idempotente |
| `vidasalud.atenciones.eventos` | 3 particiones, 3 réplicas, clave = id de atención, `delete` con retención 7 días |
| `vidasalud.catalogo.cupos` | 3 particiones, 3 réplicas, clave = `prestacionId\|fecha\|hora`, `compact` |
| Consumidores | `@KafkaListener`, grupo `vidasalud-analitica` (6 miembros, 2 tópicos) y `vidasalud-alertas` (3 miembros) |
| Errores | JSON inválido → se registra y se omite sin reintentos; fallo transitorio → 3 reintentos y se omite; duplicados descartados por `eventId` |
| Administración | Kafka UI (`:8090`) y `ms-vidasalud-kafka-admin` (`/api/admin/kafka/**`, solo Admin) |
| Tiempo real | `GET /api/analytics/resumen` y pantalla **Kafka en vivo** del front (se actualiza sola cada 5 s) |

### Estructura de los eventos (JSON)
`vidasalud.atenciones.eventos`:

| Campo | Descripción |
|---|---|
| `eventId` | UUID del evento (deduplicación) |
| `version` | Versión del esquema (entero) |
| `tipo` | `ESTADO`, `CONFIRMADA`, `RECHAZADA`, … |
| `atencionId` | Id de la atención (también es la **clave** del mensaje) |
| `estado` | Estado de la atención (`SOLICITADA`, `CONFIRMADA`, `CANCELADA`, …) |
| `motivo` | Motivo (p. ej. rechazo por falta de cupo) |
| `paciente`, `prestacion`, `fecha`, `hora` | Datos de la atención |
| `ocurridoEn` | Instante del evento (ISO-8601) |

`vidasalud.catalogo.cupos`: `eventId`, `version`, `prestacionId`, `fecha`, `hora`, `disponibles` (cupos restantes) y `ocurridoEn`; la clave es `prestacionId|fecha|hora`.

Detalle, demo y pruebas: `docs/EP5-kafka.md`.

## Alta disponibilidad: dos instancias EC2
Modelo **activo-pasivo**: EC2 **A** ejecuta todo; EC2 **B** tiene las imágenes construidas y los contenedores detenidos. Cada 5 min se copia un respaldo de PostgreSQL de A a B; si A cae, `deploy/ha/failover.sh` restaura la base en B, levanta el stack y mueve la IP elástica. Pérdida máxima de datos (RPO): 5 minutos. Los clústeres de RabbitMQ y Kafka se recrean en B (sus mensajes no se replican). Detalle y límites: `docs/HA-activo-pasivo.md`.

## Despliegue (resumen; detalle en `docs/DESPLIEGUE-AWS-AZURE.md`)
1. **Azure (Entra ID):** registros `vidasalud-api` (scope `access_as_user`, App roles, `requestedAccessTokenVersion: 2`) y `vidasalud-spa` (Redirect URI SPA para cada URL del front), usuarios con rol.
2. **AWS EC2** (`t3.large`, Ubuntu, con swap de 4 GB): `deploy/aws/ec2-bootstrap.sh`; clonar los repos (backends en `Backend/`, front en `frontend-vidasalud/`); `cp .env.example .env` y completar.
3. `docker compose up -d --build` (con `COMPOSE_FILE=compose.yaml:compose.kafka.yaml` levanta RabbitMQ, Kafka, bases, 6 servicios, front y Caddy). Los servicios Java tardan 1-2 min en estar listos tras construir.
4. **API Gateway:** `deploy/aws/create-api-gateway.sh <ec2> <tenant> <api-client-id> <origen-front>`; añadir cada origen del front al CORS.
5. **Front público:** Caddy con `SITE_HOST=<IP>.sslip.io`, o **Vercel** (build `npm run build`, salida `dist/frontend-vidasalud/browser`, variables `ENTRA_*` y `API_BASE_URL`). Registrar la URL como Redirect URI SPA y agregarla a `FRONTEND_URLS` del BFF.
6. **Repos:** `bash deploy/publicar-repos.sh` (desde la raíz) sube los 8 repositorios a GitHub.

Variables en `.env` (nunca se sube): `ENTRA_*`, `RABBITMQ_*`, `POSTGRES_*`, `FRONTEND_URLS`, `SITE_HOST`, `API_BASE_URL`, `KAFKA_UI_USER`, `KAFKA_UI_PASSWORD`, `COMPOSE_FILE`, `DLQ_LISTENER_ENABLED`. Plantilla en `.env.example`.

### Puertos expuestos (Security Group)
| Puerto | Servicio | Recomendación |
|---|---|---|
| 80/443 | Caddy (front) | público |
| 8084 | BFF (lo llama API Gateway) | público; el BFF revalida JWT y rol |
| 8090 | Kafka UI | solo tu IP, cerrar al terminar |
| 15672 | Consola RabbitMQ | solo tu IP, cerrar al terminar |
| 22 | SSH | solo tu IP (y el propio SG para el respaldo A → B) |

## Pruebas
**Seguridad (EP1)**

| Prueba | Resultado esperado |
|---|---|
| Sin token | 401 |
| Token inválido | 401 |
| Rol válido (p. ej. Recepcionista lista prestaciones) | 200 |
| Sin permiso (Paciente en `/api/admin/**` o creando prestaciones) | 403 |
| Regla de negocio inválida (fecha pasada/domingo; salto de estado) | 422 |
| Regla de negocio válida (agendar y confirmar) | 201 / 202 |

**Kafka (EP3/EP5)**

| Prueba | Resultado esperado |
|---|---|
| Agendar y confirmar una atención | Eventos con clave en `atenciones.eventos` y `catalogo.cupos`; lag 0 en ambos grupos |
| Evento con JSON inválido | Ambos grupos lo registran y lo omiten; no se reintenta ni se detiene el consumo |
| Detener y reiniciar un consumidor | El grupo pasa a `EMPTY` con lag acumulado y, al volver, `STABLE` con lag 0 |
| Detener un broker | Particiones sub-replicadas, nuevo líder, los eventos se siguen publicando; al volver, ISR completo |
| Retención | Visible en Kafka UI → Topics → Settings |
| Coexistencia con RabbitMQ | Con Kafka caído el flujo de confirmación por RabbitMQ sigue funcionando |

Cada microservicio tiene sus pruebas con `./gradlew test`.

## Limitaciones conocidas
- La guía EP1 menciona Oracle Autonomous DB; este proyecto usa **PostgreSQL** (decisión del equipo).
- API Gateway (HTTP API) llama al BFF por su IP pública, y AWS no publica un rango fijo para limitar el puerto 8084 solo a API Gateway. La defensa es que el BFF revalida firma, emisor, audiencia y rol en cada llamada; el cierre completo requeriría VPC Link con un balanceador privado.
- Los clústeres de RabbitMQ (2 nodos) y Kafka (3 brokers) corren **en una misma EC2**: demuestran replicación y tolerancia a la caída de un nodo, pero no a la caída del servidor; para eso existe la instancia en espera (activo-pasivo).
- Quorum queues con 2 nodos no toleran la caída de un nodo (demo del clúster).
- La analítica de Kafka vive en memoria y se reinicia con el servicio.
- Historial clínico y videollamada son de demostración (sin microservicio de fichas ni WebRTC entre pares).
- AWS Academy (Learner Lab) limita instancias y la sesión; la IP pública cambia si se detiene la instancia (usar Elastic IP).
- Tras reconstruir servicios, el BFF puede responder 403 mientras un servicio interno aún arranca; esperar ~90 s.
