#!/usr/bin/env bash
# EC2 B (en espera). Comprueba si el BFF de A responde. Sale con código 0 si A está sana, 1 si no.
# Uso:  deploy/ha/check-primary.sh <IP_PRIVADA_DE_A>
# Cron opcional (cada minuto, solo deja registro):  * * * * * /home/ubuntu/vidasalud-infra/deploy/ha/check-primary.sh 172.31.X.X >> /home/ubuntu/ha-check.log 2>&1
set -u
PRIMARY="${1:?Uso: check-primary.sh <IP_PRIVADA_DE_A>}"
FALLOS=0
for i in 1 2 3; do
  if curl -fsS --max-time 5 "http://$PRIMARY:8084/api/health" >/dev/null 2>&1; then
    echo "$(date -Is) primaria OK"
    exit 0
  fi
  FALLOS=$((FALLOS + 1))
  sleep 5
done
echo "$(date -Is) PRIMARIA NO RESPONDE ($FALLOS/3 intentos fallidos)"
exit 1
