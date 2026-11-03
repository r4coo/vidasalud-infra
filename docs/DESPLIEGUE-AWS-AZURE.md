# Despliegue en AWS + Azure (Entra ID) — VidaSalud

Arquitectura (EP1 + EP2):

```
Navegador (Angular + MSAL) ──login──► Microsoft Entra ID (Azure)
   │  (CloudFront + S3, HTTPS)              │ access token (JWT, claim roles)
   ▼                                        ▼
AWS API Gateway (HTTP API, JWT authorizer) ──► EC2: ms-vidasalud-bff :8084 (valida JWT + rol)
                                                   ├─ ms-vidasalud-appointments :8082 ─┐
                                                   ├─ ms-vidasalud-catalog      :8087 ─┼─ RabbitMQ (rabbit1 + rabbit2)
                                                   ├─ ms-vidasalud-notification :8085 ─┤
                                                   └─ ms-vidasalud-rabbit-admin :8088 ─┘   + 3 × PostgreSQL
```
Todo el backend corre con `docker compose` en una sola EC2. Solo el puerto 8084 (BFF) debe ser alcanzable desde API Gateway.

## 1. Azure — Entra ID
**Opción A (script):** `az login` con un administrador del tenant y
`./deploy/azure/setup-entra.sh <dominio.onmicrosoft.com> <url-front-https>` (si aún no tienes la URL del front, déjalo vacío y agrega el redirect después). Imprime los tres IDs para el `.env`.

**Opción B (portal)** — Microsoft Entra ID → App registrations:
1. **vidasalud-api**: Single tenant. *Expose an API* → Application ID URI `api://<client-id>`; agregar scope `access_as_user` (Admins and users). *Manifest*: `"requestedAccessTokenVersion": 2` (en `api`). *App roles* (allowed member types: Users): `Admin`, `Recepcionista`, `Paciente`.
2. **vidasalud-spa**: Single tenant. *Authentication* → plataforma **Single-page application** con redirect URIs `http://localhost:4200` y la URL HTTPS de CloudFront. *API permissions* → My APIs → vidasalud-api → `access_as_user` (+ Grant admin consent).
3. *Enterprise applications → vidasalud-api → Users and groups*: crear 3 usuarios (Admin, Recepcionista, Paciente) y asignar a cada uno su rol. Marcar *Assignment required = Yes* (opcional).
4. Anotar: Tenant ID, Client ID de la SPA, Client ID de la API → `.env`.

## 2. AWS — EC2 (backend)
1. Lanzar EC2 **t3.xlarge** (mínimo t3.large), Amazon Linux 2023 o Ubuntu 22.04, disco 30 GB. Security group: 22 (tu IP), **8084 (abierto a Internet o, mejor, restringido)**, 15672 solo tu IP si quieres la consola RabbitMQ (compose la expone). No abrir 5672/5432.
2. `scp deploy/aws/ec2-bootstrap.sh` y ejecutarlo; re-entrar a la sesión.
3. Subir el repo (`git clone` del repositorio `vidasalud-platform` o `scp`), `cp .env.example .env` y completar `ENTRA_*`, `RABBITMQ_*`, `POSTGRES_*`, `FRONTEND_URLS=https://<cloudfront>,http://localhost:4200`.
4. `docker compose up -d --build rabbit1 rabbit2 db-appointments db-catalog db-notifications ms-vidasalud-appointments ms-vidasalud-catalog ms-vidasalud-notification ms-vidasalud-rabbit-admin ms-vidasalud-bff` (el servicio `frontend-vidasalud` del compose es solo para pruebas locales; en AWS el front va a S3).
5. Comprobar: `curl http://localhost:8084/api/health` y `curl -i http://localhost:8084/api/appointments` → **401**. Consola RabbitMQ `http://<ec2>:15672`: ver el clúster de 2 nodos y las 6 colas.

## 3. AWS — API Gateway
`./deploy/aws/create-api-gateway.sh <ec2-dns> <tenant-id> <api-client-id> <https-del-front>` crea HTTP API + autorizador JWT (issuer `https://login.microsoftonline.com/<tenant>/v2.0`, audience = Client ID de la API) + rutas `ANY /api/{proxy+}` (protegida), `OPTIONS` y `GET /api/health` (públicas) + CORS. Devuelve `https://<id>.execute-api.<región>.amazonaws.com`.
El BFF vuelve a validar firma, issuer, audience y rol (defensa en profundidad), así que no depende solo del gateway.

## 4. AWS — Front (S3 + CloudFront)
`./deploy/aws/deploy-frontend.sh <bucket-unico> <tenant> <spa-client-id> <api-client-id> <url-api-gateway>`
Imprime `https://dxxxx.cloudfront.net`: agrégala como redirect URI SPA en Entra ID y en `FRONTEND_URLS` del `.env` en EC2 (`docker compose up -d ms-vidasalud-bff`). Además, si no estaba, agrégala al CORS del API Gateway (`aws apigatewayv2 update-api --cors-configuration ...`).

## 5. Pruebas EP1 (evidencia: capturas/Postman)
Obtener tokens iniciando sesión en el front (DevTools → Application → Session Storage) o con Postman (OAuth 2.0, Authorization Code + PKCE, scope `api://<api-client-id>/access_as_user`).

| # | Prueba | Llamada | Esperado |
|---|---|---|---|
| 1 | Sin token | `GET {API}/api/appointments` | 401 |
| 2 | Token inválido | `Authorization: Bearer abc` | 401 |
| 3 | Rol válido | Recepcionista: `GET /api/catalog/prestaciones` | 200 |
| 4 | Sin permiso | Paciente: `POST /api/catalog/prestaciones` o cualquier `/api/admin/**` | 403 |
| 5 | Regla de negocio inválida | Paciente: `POST /api/appointments` con fecha pasada o domingo; o `PUT /{id}/estado` a `EN_ATENCION` desde `SOLICITADA` | 422 |
| 6 | Regla de negocio válida | Paciente crea atención futura (201); Recepcionista confirma (202) y a los segundos queda `CONFIRMADA` | 201/202 |

## 6. Pruebas EP2 (RabbitMQ) — ver `docs/EP2-guia-demo.md`

## Advertencias
- **Base de datos:** la guía EP1 pide Oracle Autonomous DB; este proyecto usa **PostgreSQL** por decisión del equipo. Si el docente lo exige, hay que migrar JDBC/Flyway (cambia dialecto y tipos de las migraciones).
- **Quorum queues con 2 nodos** no toleran la caída de un nodo (se necesita mayoría); sirve para la demo del clúster, no como HA real (usar 3 nodos).
- **Costos AWS:** detener la EC2 y borrar CloudFront/API Gateway al terminar.
- Los scripts y el código **no se ejecutaron ni compilaron** en el entorno donde se generaron (sin acceso a npm/Maven/AWS/Azure). Lo primero: `docker compose build` y `npm run build`, y corregir errores de compilación si aparecen.
- No subas `.env` a GitHub (está en `.gitignore`).
