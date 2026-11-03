#!/usr/bin/env bash
# Inicializa y sube los 7 repositorios a GitHub (usuario r4coo).
# 1) Crea ANTES los 7 repos VACÍOS en https://github.com/new (sin README ni .gitignore), públicos o privados.
# 2) Ejecuta desde la raíz del proyecto, en Git Bash:  bash deploy/publicar-repos.sh
set -euo pipefail
USER_GH="${GH_USER:-r4coo}"
if [ -z "$(git config --global user.name)" ] || [ -z "$(git config --global user.email)" ]; then
  echo "Falta tu identidad de Git. Ejecuta primero:"
  echo '  git config --global user.name "Tu Nombre"'
  echo '  git config --global user.email "tu-correo@ejemplo.com"'
  exit 1
fi
git config --global core.autocrlf true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

push_repo() { # carpeta nombre-repo
  local dir="$1" name="$2"
  echo "== $name"
  cd "$dir"
  [ -d .git ] || git init -q -b main
  git add -A
  if git rev-parse --verify -q HEAD >/dev/null && git diff --cached --quiet; then
    echo "  (sin cambios nuevos)"
  else
    git commit -q -m "Versión inicial: $name"
  fi
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$USER_GH/$name.git"
  git push -u origin main
}

for s in ms-vidasalud-bff ms-vidasalud-appointments ms-vidasalud-catalog ms-vidasalud-notification ms-vidasalud-rabbit-admin; do
  push_repo "$ROOT/Backend/$s" "$s"
done
push_repo "$ROOT/frontend-vidasalud" frontend-vidasalud
# Infraestructura: compose, rabbitmq, deploy, docs (Backend/ y frontend/ van ignorados)
push_repo "$ROOT" vidasalud-infra
echo "Listo. Verifica que ningún .env/.pem se haya subido."
