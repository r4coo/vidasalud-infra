#!/usr/bin/env bash
# EC2 B (en espera). Prepara la máquina: swap, Docker, repos y imágenes construidas, SIN levantar contenedores.
# Antes: clona la infra  git clone https://github.com/r4coo/vidasalud-infra.git  y copia el .env de A.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
USER_GH="${GH_USER:-r4coo}"

if ! swapon --show | grep -q .; then
  sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
sudo apt-get update -y && sudo apt-get install -y rsync git
if ! command -v docker >/dev/null; then
  bash deploy/aws/ec2-bootstrap.sh
  echo "Docker instalado. Cierra la sesión SSH, vuelve a entrar y ejecuta de nuevo este script."
  exit 0
fi

mkdir -p Backend "$HOME/backups-from-a"
for r in ms-vidasalud-bff ms-vidasalud-appointments ms-vidasalud-catalog ms-vidasalud-notification ms-vidasalud-rabbit-admin ms-vidasalud-kafka-admin; do
  [ -d "Backend/$r" ] && git -C "Backend/$r" pull || git clone "https://github.com/$USER_GH/$r.git" "Backend/$r"
done
[ -d frontend-vidasalud ] && git -C frontend-vidasalud pull || git clone "https://github.com/$USER_GH/frontend-vidasalud.git" frontend-vidasalud

[ -f .env ] || { echo "Falta .env: cópialo desde A (scp ubuntu@<IP_A>:vidasalud-infra/.env .env) y repite."; exit 1; }
echo "Construyendo imágenes en serie (tarda varios minutos)..."
COMPOSE_PARALLEL_LIMIT=1 docker compose build
echo "Listo: B queda en espera. No levantes contenedores aquí mientras A esté activa."
