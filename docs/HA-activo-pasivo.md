# Alta disponibilidad: dos EC2 (activo-pasivo)

Objetivo: si la EC2 principal (**A**) cae, la EC2 en espera (**B**) levanta el proyecto con los datos recientes.

```
                       IP elástica (SITE_HOST, API Gateway)
                                   │  ← se mueve de A a B en el failover
        ┌──────────────────────────┴───────────────┐
   EC2 A (activa)                              EC2 B (en espera)
   stack completo corriendo                    stack construido, contenedores detenidos
   PostgreSQL ──── pg_dump cada 5 min ────────►  ~/backups-from-a  (últimos 12)
```

## Qué se replica y qué no

| Componente | En el failover |
|---|---|
| PostgreSQL (3 bases: atenciones, catálogo, notificaciones) | Se restaura el último respaldo. Pérdida máxima (RPO): 5 minutos |
| RabbitMQ (2 nodos) | Se levanta de nuevo; la topología la declaran los servicios. Los mensajes en cola en ese instante se pierden |
| Kafka (3 brokers) | Se levanta de nuevo; `kafka-init` recrea los tópicos. El historial de eventos anterior no se conserva |
| Analítica en memoria | Se reinicia en cero |
| Entra ID y API Gateway | No cambian: API Gateway apunta a la IP elástica |
| Certificado HTTPS | Caddy lo emite de nuevo para el mismo `SITE_HOST` |

Límite: RabbitMQ y Kafka mantienen sus clústeres dentro de **una misma máquina**, así que la tolerancia a fallos es a nivel de servidor (A → B), no de cada clúster.

## Preparación (una vez)

**Security Group:** usa el mismo en A y B y agrega una regla de entrada SSH (22) cuyo origen sea ese mismo Security Group (así A puede copiar archivos a B por la IP privada). El puerto 8084 también debe permitir el tráfico de B hacia A.

**En B** (instancia nueva t3.large, Ubuntu, mismo Security Group):
```bash
git clone https://github.com/r4coo/vidasalud-infra.git && cd vidasalud-infra
scp ubuntu@<IP_PRIVADA_A>:vidasalud-infra/.env .env    # mismas claves que A
bash deploy/ha/setup-standby.sh      # si instala Docker, cierra sesión, vuelve a entrar y repítelo
```

**En A** (clave SSH hacia B y respaldo automático):
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519      # si no existe
cat ~/.ssh/id_ed25519.pub                             # agrégala en B: ~/.ssh/authorized_keys
bash deploy/ha/backup-a.sh <IP_PRIVADA_B>             # prueba manual
( crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/vidasalud-infra/deploy/ha/backup-a.sh <IP_PRIVADA_B> >> $HOME/ha-backup.log 2>&1" ) | crontab -
```
Comprueba en B: `ls ~/backups-from-a` debe listar carpetas con fecha.

## Failover (A cayó)

1. En B: `bash deploy/ha/failover.sh <IP_PRIVADA_A>`
   Verifica que A no responde (`check-primary.sh`), restaura el último respaldo y levanta todo (`docker compose up -d --build`).
2. En la consola de AWS: **EC2 → Elastic IPs →** tu IP **→ Actions → Associate Elastic IP address →** instancia B, marcando *Allow reassociation*.
3. Verifica: `https://<SITE_HOST>`, inicio de sesión, `GET /api/health` y una atención de prueba.

Tiempo de recuperación (RTO) estimado: 3–5 minutos más el cambio de IP.

## Prueba para la demostración

Con A activa y al menos un respaldo en B:
1. En A: `docker compose stop ms-vidasalud-bff` (simula la caída; también sirve detener la instancia en la consola).
2. En B: `bash deploy/ha/check-primary.sh <IP_PRIVADA_A>` → "PRIMARIA NO RESPONDE".
3. En B: `bash deploy/ha/failover.sh <IP_PRIVADA_A>` y luego mover la IP elástica a B.
4. Abrir el front y comprobar que las atenciones creadas antes de la caída siguen ahí.

Si en la prueba A sigue encendida, deténla (`docker compose down`) o la IP elástica terminará apuntando a un stack con datos distintos.

## Volver a A (failback)

Con A de nuevo en línea y B activa: en B ejecuta un respaldo (adapta `backup-a.sh` apuntando a A) o `docker exec db_<x> pg_dump ... | gzip`, restáuralo en A con `restore-on-b.sh` (copiando la carpeta a `~/backups-from-a` de A), detén B (`docker compose down`) y mueve la IP elástica de nuevo a A.

## Notas del Learner Lab

- Las instancias se detienen al terminar la sesión y los contenedores no arrancan solos: tras iniciar, en A ejecuta `docker compose up -d`. B puede quedar detenida cuando no la necesites.
- La IP elástica permanece asignada aunque se detengan las instancias.
- Si el cron de respaldo falla, revisa `~/ha-backup.log` en A.
