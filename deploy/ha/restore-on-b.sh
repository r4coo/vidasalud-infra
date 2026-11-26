#!/usr/bin/env bash
# EC2 B. Restaura el respaldo más reciente de A en las 3 bases (sin levantar aún los microservicios).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- || true)"; PGUSER="${PGUSER:-vidasalud}"
LATEST="$(ls -1d "$HOME"/backups-from-a/2* 2>/dev/null | sort | tail -n1 || true)"
[ -n "$LATEST" ] || { echo "No hay respaldos en ~/backups-from-a. ¿Corrió backup-a.sh en A?"; exit 1; }
echo "Restaurando $(basename "$LATEST")"

docker compose up -d db-appointments db-catalog db-notifications
for db in appointments catalog notifications; do
  for i in $(seq 1 30); do
    docker exec "db_$db" pg_isready -U "$PGUSER" -d "db_$db" >/dev/null 2>&1 && break
    sleep 2
  done
  gunzip -c "$LATEST/db_$db.sql.gz" | docker exec -i "db_$db" psql -U "$PGUSER" -d "db_$db" -q -v ON_ERROR_STOP=0 >/dev/null
  echo "  db_$db restaurada"
done
