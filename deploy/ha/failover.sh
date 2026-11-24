#!/usr/bin/env bash
# EC2 B. Failover: restaura el último respaldo y levanta todo el stack.
# Uso:  deploy/ha/failover.sh <IP_PRIVADA_DE_A> [--force]
# Se niega a actuar si A sigue respondiendo (para no tener dos primarias), salvo con --force.
set -euo pipefail
PRIMARY="${1:?Uso: failover.sh <IP_PRIVADA_DE_A> [--force]}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ "${2:-}" != "--force" ] && "$ROOT/deploy/ha/check-primary.sh" "$PRIMARY"; then
  echo "La primaria SÍ responde. No se hace failover (usa --force si es una prueba)."
  exit 1
fi

"$ROOT/deploy/ha/restore-on-b.sh"
docker compose up -d --build
echo
docker compose ps
cat <<MSG

Stack levantado en B con los datos del último respaldo.
SIGUIENTE (manual, en la consola de AWS): asociar la IP elástica a esta instancia
  EC2 > Elastic IPs > (tu IP) > Actions > Associate Elastic IP address > instancia B
  y marcar "Allow this Elastic IP address to be reassociated".
Después comprueba:  curl -s https://<SITE_HOST>   y   el login del front.
MSG
