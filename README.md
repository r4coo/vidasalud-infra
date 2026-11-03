# VidaSalud — Telemedicina (EP1 Entra ID/AWS + EP2 RabbitMQ)

Caso 1 **VidaSalud**: pacientes solicitan atenciones; recepción las confirma (reserva de cupo asíncrona vía RabbitMQ); se atienden por videollamada.

| Carpeta | Rol | Puerto |
|---|---|---|
| `frontend-vidasalud/` | Angular 18 + MSAL (Entra ID) | 4200 / 3000 |
| `Backend/ms-vidasalud-bff/` | BFF: valida JWT Entra ID + roles, enruta | 8084 |
| `Backend/ms-vidasalud-appointments/` | Principal: atenciones, estados, auditoría (PostgreSQL) | 8082 |
| `Backend/ms-vidasalud-catalog/` | Catálogo: prestaciones, boxes, cupos; consume `q.atenciones.confirmar` | 8087 |
| `Backend/ms-vidasalud-notification/` | Consume `q.notificaciones` | 8085 |
| `Backend/ms-vidasalud-rabbit-admin/` | Administración de colas/exchanges/bindings (REST, solo Admin) | 8088 |
| `compose.yaml` | RabbitMQ clúster (rabbit1+rabbit2), 3 PostgreSQL, todos los servicios | |
| `deploy/`, `docs/` | Scripts y guía AWS + Azure; guía de demo EP2 | |

Roles (Entra ID App roles): **Admin**, **Recepcionista**, **Paciente**.

## Ejecutar en local
```bash
cp .env.example .env        # sin ENTRA_* el front arranca en modo demo, pero el BFF exige token
docker compose up -d --build
# Front: http://localhost:3000   BFF: http://localhost:8084   RabbitMQ: http://localhost:15672
```
Despliegue en la nube: **`docs/DESPLIEGUE-AWS-AZURE.md`**. Demo de RabbitMQ: **`docs/EP2-guia-demo.md`**.

## Mensajería (resumen)
Exchanges `vidasalud.atenciones.direct` (comandos), `vidasalud.eventos.topic` (eventos), `vidasalud.dlx.direct` (DLX). Colas `q.atenciones.confirmar`, `q.notificaciones`, `q.auditoria`, cada una con `.dlq`. ACK manual; reintentos acotados (3) y luego NACK sin requeue → DLQ, con listener que registra el mensaje fallido.

## Limitaciones conocidas
- No se compiló ni se ejecutó nada en el entorno de generación: ejecutar `./gradlew test` en cada servicio y `npm run build` en el front.
- PostgreSQL en lugar de Oracle (la guía EP1 menciona Oracle Autonomous DB).
- El historial clínico y la videollamada son de demostración (sin microservicio de fichas ni WebRTC entre pares).
- Para publicar: un repositorio de GitHub por componente (ver guías), cada uno con su `.gitignore` y `README`.
