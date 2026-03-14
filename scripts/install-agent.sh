#!/usr/bin/env bash
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────

UPDATES_REPO="${UPDATES_REPO:-alphaoflogic-ua/smart-home-updates}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}"

AGENT_DEST="${AGENT_DEST:-/opt/station-agent}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/var/lib/station-agent}"
DEPLOY_DIR="${DEPLOY_DIR:-${HOME}/smart-home}"
SERVICE_NAME="station-agent"

# ── guard: needs a real TTY for interactive prompts ───────────────────────────

if [ ! -t 0 ]; then
  TMP=$(mktemp /tmp/install-agent.XXXXXX.sh)
  curl -fsSL "${RAW}/install-agent.sh" -o "$TMP"
  chmod +x "$TMP"
  echo "Re-running with TTY..."
  exec bash "$TMP" "$@" < /dev/tty
fi

# ── helpers ───────────────────────────────────────────────────────────────────

log() { echo "==> $*"; }

download() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL "${RAW}/${src}" -o "$dest"
}

env_current() {
  local file="$1"
  local key="$2"
  if [ -f "$file" ]; then
    grep -m1 "^${key}=" "$file" | cut -d= -f2- | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//' || true
  fi
}

prompt_value() {
  local prompt_text="$1"
  local default="$2"
  local required="${3:-false}"
  local secret="${4:-false}"
  local value=""

  while true; do
    if [ "$secret" = "true" ]; then
      if [ -n "$default" ]; then
        printf "%s [press Enter to keep current]: " "$prompt_text" >&2
      else
        printf "%s: " "$prompt_text" >&2
      fi
      read -rs value
      echo >&2
    else
      if [ -n "$default" ]; then
        read -rp "$prompt_text [$default]: " value
      else
        read -rp "$prompt_text: " value
      fi
    fi

    if [ -z "$value" ] && [ -n "$default" ]; then
      value="$default"
    fi

    value=$(echo "$value" | xargs || true)

    if [ "$required" = "true" ] && [ -z "$value" ]; then
      echo "Value is required." >&2
      continue
    fi

    printf "%s" "$value"
    return 0
  done
}

# ── [1/6] prerequisites ───────────────────────────────────────────────────────

log "[1/6] Checking prerequisites..."

if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y curl
fi

if ! command -v node >/dev/null 2>&1; then
  log "Node.js not found. Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

echo "Node.js: $(node --version)"

# ── [2/6] docker ──────────────────────────────────────────────────────────────

log "[2/6] Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo apt-get install -y docker-compose-plugin bluez util-linux rfkill
  sudo systemctl enable --now docker bluetooth
  sudo rfkill unblock bluetooth 2>/dev/null || true
  sudo usermod -aG docker "$USER"
  log "Docker installed. Re-running in docker group context..."
  exec newgrp docker "$0" "$@"
fi

if ! docker ps >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER"
  log "Re-running in docker group context..."
  exec newgrp docker "$0" "$@"
fi

echo "Docker: $(docker --version)"

# ── [3/6] download deployment files ──────────────────────────────────────────

log "[3/6] Downloading deployment files to $DEPLOY_DIR..."

mkdir -p "$DEPLOY_DIR/nginx/conf.d" "$DEPLOY_DIR/nginx/certs" "$DEPLOY_DIR/scripts"

download "docker-compose.yml"          "$DEPLOY_DIR/docker-compose.yml"
download "docker-compose.prod.yml"     "$DEPLOY_DIR/docker-compose.prod.yml"
download "nginx/conf.d/default.conf"   "$DEPLOY_DIR/nginx/conf.d/default.conf"
download "scripts/bootstrap-host.sh"  "$DEPLOY_DIR/scripts/bootstrap-host.sh"
download "scripts/deploy-station.sh"  "$DEPLOY_DIR/scripts/deploy-station.sh"

chmod +x "$DEPLOY_DIR/scripts/bootstrap-host.sh" "$DEPLOY_DIR/scripts/deploy-station.sh"

# ── [4/6] stack setup (first time) ───────────────────────────────────────────

log "[4/6] Checking station stack..."

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  log "Running station setup..."
  cd "$DEPLOY_DIR"
  bash "$DEPLOY_DIR/scripts/deploy-station.sh"
else
  log "Stack already configured — skipping."
fi

# ── [5/6] install agent ───────────────────────────────────────────────────────

log "[5/6] Installing station-agent to $AGENT_DEST..."

AGENT_FILES=(
  "station-agent/src/server.js"
  "station-agent/src/config.js"
  "station-agent/src/updater.js"
  "station-agent/src/docker.js"
  "station-agent/src/healthcheck.js"
  "station-agent/src/version.js"
  "station-agent/src/bootstrap.js"
  "station-agent/package.json"
  "station-agent/package-lock.json"
)

sudo mkdir -p "$AGENT_DEST/src"
sudo mkdir -p "$AGENT_DATA_DIR"

for file in "${AGENT_FILES[@]}"; do
  dest="$AGENT_DEST/${file#station-agent/}"
  sudo mkdir -p "$(dirname "$dest")"
  curl -fsSL "${RAW}/${file}" | sudo tee "$dest" > /dev/null
done

sudo chown -R "$USER":"$USER" "$AGENT_DEST"
sudo chown -R "$USER":"$USER" "$AGENT_DATA_DIR"

log "Installing npm dependencies..."
cd "$AGENT_DEST"
npm install --omit=dev --silent

# ── [6/6] configure agent .env + systemd ─────────────────────────────────────

log "[6/6] Configuring agent..."

STACK_ENV="$DEPLOY_DIR/.env"

stack_station_id=$(env_current "$STACK_ENV" "STATION_ID")
cur_station_id=$(env_current "$AGENT_DEST/.env" "STATION_ID")
cur_update_url=$(env_current "$AGENT_DEST/.env" "UPDATE_SERVER_URL")
cur_interval=$(env_current "$AGENT_DEST/.env" "CHECK_INTERVAL_MINUTES")
cur_auto=$(env_current "$AGENT_DEST/.env" "AUTO_UPDATE")
cur_healthcheck=$(env_current "$AGENT_DEST/.env" "HEALTHCHECK_URL")
cur_docker_user=$(env_current "$AGENT_DEST/.env" "DOCKER_USERNAME")
cur_docker_token=$(env_current "$AGENT_DEST/.env" "DOCKER_TOKEN")
cur_agent_token=$(env_current "$AGENT_DEST/.env" "AGENT_TOKEN")

station_id=$(prompt_value "Station ID" "${cur_station_id:-${stack_station_id:-}}" true false)
update_url=$(prompt_value "Update manifest URL" "${cur_update_url:-https://raw.githubusercontent.com/alphaoflogic-ua/smart-home-updates/main/release.json}" true false)
check_interval=$(prompt_value "Check interval (minutes)" "${cur_interval:-60}" false false)
auto_update=$(prompt_value "Auto update (true/false)" "${cur_auto:-true}" false false)
healthcheck_url=$(prompt_value "Healthcheck URL" "${cur_healthcheck:-http://localhost/api/health}" false false)
docker_username=$(prompt_value "Docker Hub username (optional)" "${cur_docker_user:-}" false false)
docker_token=$(prompt_value "Docker Hub token (optional)" "${cur_docker_token:-}" false true)
agent_token=$(prompt_value "Agent API token (optional, recommended)" "${cur_agent_token:-}" false true)

cat > "$AGENT_DEST/.env" <<EOF
STATION_ID='$station_id'
UPDATE_SERVER_URL='$update_url'
CHECK_INTERVAL_MINUTES='$check_interval'
AUTO_UPDATE='$auto_update'
BOOTSTRAP_ON_START='true'
COMPOSE_PROJECT_PATH='$DEPLOY_DIR'
COMPOSE_FILE='docker-compose.yml'
HEALTHCHECK_URL='$healthcheck_url'
DATA_DIR='$AGENT_DATA_DIR'
DOCKER_USERNAME='$docker_username'
DOCKER_TOKEN='$docker_token'
AGENT_TOKEN='$agent_token'
EOF

NODE_BIN=$(command -v node)

sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<EOF
[Unit]
Description=Station Agent — smart home auto-updater
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$AGENT_DEST
EnvironmentFile=$AGENT_DEST/.env
ExecStart=$NODE_BIN src/server.js
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 3

echo ""
echo "Done. Station agent is running."
echo ""
sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
echo ""
echo "Useful commands:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  curl http://localhost:3001/status"