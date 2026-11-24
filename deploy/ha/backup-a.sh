#!/usr/bin/env bash
# EC2 A (primaria). Respalda las 3 bases PostgreSQL y las copia a la EC2 B (en espera).
# Uso:  deploy/ha/backup-a.sh <IP_PRIVADA_DE_B>
# Cron (cada 5 min):  */5 * * * * /home/ubuntu/vidasalud-infra/deploy/ha/backup-a.sh 172.31.X.X >> /home/ubuntu/ha-backup.log 2>&1
set -euo pipefail
STANDBY="${1:?Uso: backup-a.sh <IP_PRIVADA_DE_B>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- || true)"; PGUSER="${PGUSER:-vidasalud}"
DEST="$HOME/backups-ha"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$DEST/.tmp-$STAMP"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' ERR

for db in appointments catalog notifications; do
  docker exec "db_$db" pg_dump -U "$PGUSER" -d "db_$db" --clean --if-exists | gzip > "$TMP/db_$db.sql.gz"
  [ -s "$TMP/db_$db.sql.gz" ] || { echo "Respaldo vacío de db_$db"; exit 1; }
done
mv "$TMP" "$DEST/$STAMP"          # el directorio solo aparece completo (nunca un respaldo a medias)
ls -1dt "$DEST"/2* 2>/dev/null | tail -n +13 | xargs -r rm -rf   # conserva los últimos 12

rsync -az --delete -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
  "$DEST/" "ubuntu@$STANDBY:backups-from-a/"
echo "$(date -Is) respaldo $STAMP copiado a $STANDBY"
