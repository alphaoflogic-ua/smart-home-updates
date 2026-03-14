#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/Users/andrejprudnikov/WebstormProjects/smart-home"
AGENT_DIR="$PROJECT_ROOT/station-agent"
DATA_DIR="$PROJECT_ROOT/data-agent"

mkdir -p "$DATA_DIR"

set -a
source "$AGENT_DIR/.env"
export DATA_DIR="$DATA_DIR"
export COMPOSE_PROJECT_PATH="$PROJECT_ROOT"
export HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://localhost:3000/health}"
set +a

if ! docker compose version >/dev/null 2>&1; then
  echo "[agent-start] Не найден docker compose. Установите плагин Docker Compose." >&2
  exit 1
fi

cd "$AGENT_DIR"
exec node src/server.js