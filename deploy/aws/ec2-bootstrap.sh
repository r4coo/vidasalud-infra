#!/usr/bin/env bash
# Ejecutar EN la instancia EC2 (Amazon Linux 2023 o Ubuntu 22.04+). Instala Docker + plugin compose.
# Recomendado: t3.xlarge (4 vCPU / 16 GB); mínimo t3.large (8 GB) — son 11 contenedores + 2 nodos RabbitMQ + 3 Postgres + 4 JVM.
set -euo pipefail
if command -v dnf >/dev/null; then
  sudo dnf install -y docker git
  sudo systemctl enable --now docker
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -sSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
else
  curl -fsSL https://get.docker.com | sudo sh
  sudo apt-get install -y git
fi
sudo usermod -aG docker "$USER"
echo "Listo. Cierra sesión y vuelve a entrar; luego: git clone <repo> && cd <repo> && cp .env.example .env && nano .env && docker compose up -d --build"
