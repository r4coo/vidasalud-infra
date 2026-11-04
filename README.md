# vidasalud-infra — Telemedicina VidaSalud (EP1 Entra ID/AWS + EP2 RabbitMQ)

Caso 1 **VidaSalud**: el paciente solicita una atención, recepción la confirma (reserva de cupo asíncrona vía RabbitMQ) y se atiende por videollamada.

## Repositorios
| Repositorio | Rol | Puerto |
|---|---|---|
| `frontend-vidasalud` | Angular 18 + MSAL (login Entra ID) | 80/443 (Caddy) |
| `ms-vidasalud-bff` | BFF: valida JWT de Entra ID + roles, enruta | 8084 |
| `ms-vidasalud-appointments` | Principal: atenciones, estados, auditoría (PostgreSQL) | 8082 |
| `ms-vidasalud-catalog` | Catálogo: prestaciones, boxes, cupos; consume `q.atenciones.confirmar` | 8087 |
| `ms-vidasalud-notification` | Consume `q.notificaciones` | 8085 |
| `ms-vidasalud-rabbit-admin` | Administración de colas/exchanges/bindings (REST, solo Admin) | 8088 |
| `vidasalud-infra` (este) | `compose.yaml`, RabbitMQ en clúster, Caddy, scripts de despliegue y docs | |

## Arquitectura
```
Navegador (Angular+MSAL) ──login──► Microsoft Entra ID (Azure)
   │ HTTPS (Caddy en EC2)                │ access token JWT (claim roles)
   ▼                                     ▼
AWS API Gateway (HTTP API + JWT authorizer) ──► EC2: ms-vidasalud-bff :8084 (revalida JWT y rol)
                                                    ├─ appointments ─┐
                                                    ├─ catalog       ├─ RabbitMQ (rabbit1 + rabbit2, quorum + DLQ)
                                                    ├─ notification  ┤
                                                    └─ rabbit-admin ─┘   + 3 × PostgreSQL
```
Roles (App roles de Entra ID): **Admin**, **Recepcionista**, **Paciente**.

## Mensajería (EP2)
- Exchanges: `vidasalud.atenciones.direct` (comandos), `vidasalud.eventos.topic` (eventos), `vidasalud.dlx.direct` (DLX).
- Colas quorum: `q.atenciones.confirmar`, `q.notificaciones`, `q.auditoria`, cada una con `.dlq`.
- ACK manual; error recuperable → hasta 3 reintentos; no recuperable → NACK sin requeue → DLQ con listener que registra el mensaje.
- Retención: TTL y `x-max-length` con `overflow=drop-head`.

## Despliegue (resumen; detalle en `docs/DESPLIEGUE-AWS-AZURE.md`)
1. **Azure (Entra ID):** registros `vidasalud-api` (scope `access_as_user`, App roles, `requestedAccessTokenVersion: 2`) y `vidasalud-spa` (Redirect URI SPA), usuarios con rol.
2. **AWS EC2** (`t3.large`, Ubuntu): `docker.io`, `docker-compose-v2`; clonar los 7 repos (backends en `Backend/`, front en `frontend-vidasalud/`); `cp .env.example .env` y completar.
3. `docker compose build` y `docker compose up -d` (RabbitMQ, bases, 5 servicios, front y Caddy).
4. **API Gateway:** `deploy/aws/create-api-gateway.sh <ec2> <tenant> <api-client-id> <origen-front>`.
5. **HTTPS del front:** Caddy con `SITE_HOST=<IP>.sslip.io` (Let's Encrypt); registrar esa URL como Redirect URI SPA y en el CORS de API Gateway.

Variables en `.env` (nunca se sube): `ENTRA_*`, `RABBITMQ_*`, `POSTGRES_*`, `FRONTEND_URLS`, `SITE_HOST`, `API_BASE_URL`.

## Pruebas de seguridad (EP1)
| Prueba | Resultado esperado |
|---|---|
| Sin token | 401 |
| Token inválido | 401 |
| Rol válido (p. ej. Recepcionista lista prestaciones) | 200 |
| Sin permiso (Paciente en `/api/admin/**` o creando prestaciones) | 403 |
| Regla de negocio inválida (fecha pasada/domingo; salto de estado) | 422 |
| Regla de negocio válida (agendar y confirmar) | 201 / 202 |

## Limitaciones conocidas
- La guía EP1 menciona Oracle Autonomous DB; este proyecto usa **PostgreSQL** (decisión del equipo).
- Quorum queues con 2 nodos no toleran la caída de un nodo (demo del clúster, no alta disponibilidad real).
- Historial clínico y videollamada son de demostración (sin microservicio de fichas ni WebRTC entre pares).
- AWS Academy (Learner Lab) bloquea CloudFront e instancias grandes; la sesión y la IP pública cambian si se detiene la instancia (usar Elastic IP).
