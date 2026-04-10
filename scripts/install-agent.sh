#!/usr/bin/env bash
set -euo pipefail

# ── resolve real user (even when run via sudo) ────────────────────────────────

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
  REAL_HOME=$(eval echo "~$SUDO_USER")
else
  REAL_USER="$USER"
  REAL_HOME="$HOME"
fi

# ── config ────────────────────────────────────────────────────────────────────

UPDATES_REPO="${UPDATES_REPO:-alphaoflogic-ua/smart-home-updates}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}"
BINARY_URL="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}/station-agent/station-agent-linux-arm64"

AGENT_DEST="${AGENT_DEST:-/opt/station-agent}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/var/lib/station-agent}"
DEPLOY_DIR="${DEPLOY_DIR:-${REAL_HOME}/smart-home}"
SERVICE_NAME="station-agent"

# ── guard: needs a real TTY for interactive prompts ───────────────────────────

if [ ! -t 0 ] && [ -z "${_INSTALL_REEXEC:-}" ]; then
  TMP=$(mktemp /tmp/install-agent.XXXXXX.sh)
  curl -fsSL "${RAW}/install-agent.sh" -o "$TMP"
  chmod +x "$TMP"
  echo "Re-running with TTY..."
  _INSTALL_REEXEC=1 exec bash "$TMP" "$@" < /dev/tty
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
      read -rs value < /dev/tty
      echo >&2
    else
      if [ -n "$default" ]; then
        read -rp "$prompt_text [$default]: " value < /dev/tty
      else
        read -rp "$prompt_text: " value < /dev/tty
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

# ── [1/5] docker ──────────────────────────────────────────────────────────────

log "[1/5] Checking Docker..."

if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y curl
fi

if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo apt-get install -y docker-compose-plugin bluez util-linux rfkill
  sudo systemctl enable --now docker
  sudo rfkill unblock bluetooth 2>/dev/null || true
  sudo systemctl enable bluetooth 2>/dev/null || true
  sudo systemctl start bluetooth 2>/dev/null || true
  sudo usermod -aG docker "$REAL_USER"
  log "Docker installed. Re-running in docker group context..."
  exec newgrp docker "$0" "$@"
fi

if ! docker ps >/dev/null 2>&1; then
  sudo usermod -aG docker "$REAL_USER"
  log "Re-running in docker group context..."
  exec newgrp docker "$0" "$@"
fi

echo "Docker: $(docker --version)"

# ── hostname for mDNS ─────────────────────────────────────────────────────────

STATION_HOSTNAME="${STATION_HOSTNAME:-smartstation}"
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$STATION_HOSTNAME" ]; then
  log "Setting hostname to $STATION_HOSTNAME (was $CURRENT_HOSTNAME)..."
  sudo hostnamectl set-hostname "$STATION_HOSTNAME"
  echo "Devices will reach MQTT broker at ${STATION_HOSTNAME}.local"
else
  log "Hostname already set to $STATION_HOSTNAME"
fi

# ── [2/5] docker hub login ───────────────────────────────────────────────────

log "[2/5] Docker Hub credentials (needed to pull private images)..."

cur_docker_user=$(env_current "$AGENT_DEST/.env" "DOCKER_USERNAME")
cur_docker_token=$(env_current "$AGENT_DEST/.env" "DOCKER_TOKEN")

docker_username=$(prompt_value "Docker Hub username" "${cur_docker_user:-}" true false)
docker_token=$(prompt_value "Docker Hub token" "${cur_docker_token:-}" true true)

echo "$docker_token" | docker login -u "$docker_username" --password-stdin
echo "Docker Hub: logged in as $docker_username"

# ── [3/5] download deployment files ──────────────────────────────────────────

log "[3/5] Downloading deployment files to $DEPLOY_DIR..."

mkdir -p "$DEPLOY_DIR/nginx/conf.d" "$DEPLOY_DIR/nginx/certs" "$DEPLOY_DIR/scripts"

download "docker-compose.yml"         "$DEPLOY_DIR/docker-compose.yml"
download "docker-compose.prod.yml"    "$DEPLOY_DIR/docker-compose.prod.yml"
download "nginx/conf.d/default.conf"  "$DEPLOY_DIR/nginx/conf.d/default.conf"
download "scripts/bootstrap-host.sh" "$DEPLOY_DIR/scripts/bootstrap-host.sh"
download "scripts/deploy-station.sh" "$DEPLOY_DIR/scripts/deploy-station.sh"

chmod +x "$DEPLOY_DIR/scripts/bootstrap-host.sh" "$DEPLOY_DIR/scripts/deploy-station.sh"

# Ensure deploy dir is owned by the real user so the agent can sync compose files
chown -R "$REAL_USER":"$REAL_USER" "$DEPLOY_DIR"

# ── [3/5] stack setup (first time) ───────────────────────────────────────────

log "[3/5] Checking station stack..."

if [ ! -f "$DEPLOY_DIR/.env" ]; then
  log "Running station setup..."
  cd "$DEPLOY_DIR"
  bash "$DEPLOY_DIR/scripts/deploy-station.sh"
else
  log "Stack already configured — skipping."
  # Ensure FIRMWARE_CACHE_DIR is set (added in v0.2.10+)
  if ! grep -q '^FIRMWARE_CACHE_DIR=' "$DEPLOY_DIR/.env"; then
    echo "FIRMWARE_CACHE_DIR='${REAL_HOME}/firmware-cache'" >> "$DEPLOY_DIR/.env"
    log "Added FIRMWARE_CACHE_DIR to stack .env"
  fi
fi

# ── [4/5] install agent binary ────────────────────────────────────────────────

log "[4/5] Installing station-agent binary to $AGENT_DEST..."

sudo mkdir -p "$AGENT_DEST"
sudo mkdir -p "$AGENT_DATA_DIR"

curl -fsSL "$BINARY_URL" | sudo tee "$AGENT_DEST/station-agent" > /dev/null
sudo chmod +x "$AGENT_DEST/station-agent"
# Allow binding to port 80 for captive portal (runs as non-root user)
sudo setcap cap_net_bind_service=+ep "$AGENT_DEST/station-agent"

sudo chown -R "$REAL_USER":"$REAL_USER" "$AGENT_DEST"
sudo chown -R "$REAL_USER":"$REAL_USER" "$AGENT_DATA_DIR"

FIRMWARE_CACHE_DIR="$REAL_HOME/firmware-cache"
mkdir -p "$FIRMWARE_CACHE_DIR"
chown "$REAL_USER":"$REAL_USER" "$FIRMWARE_CACHE_DIR"

# ── [5/5] configure .env + systemd ───────────────────────────────────────────

log "[5/5] Configuring agent..."

STACK_ENV="$DEPLOY_DIR/.env"

stack_station_id=$(env_current "$STACK_ENV" "STATION_ID")
cur_station_id=$(env_current  "$AGENT_DEST/.env" "STATION_ID")
cur_update_url=$(env_current  "$AGENT_DEST/.env" "UPDATE_SERVER_URL")
cur_interval=$(env_current    "$AGENT_DEST/.env" "CHECK_INTERVAL_MINUTES")
cur_auto=$(env_current        "$AGENT_DEST/.env" "AUTO_UPDATE")
cur_agent_token=$(env_current "$AGENT_DEST/.env" "AGENT_API_TOKEN")
[ -z "$cur_agent_token" ] && cur_agent_token=$(env_current "$AGENT_DEST/.env" "AGENT_TOKEN")
cur_backend_agent_token=$(env_current "$AGENT_DEST/.env" "BACKEND_AGENT_TOKEN")
stack_agent_token=$(env_current "$STACK_ENV" "AGENT_TOKEN")

station_id=$(prompt_value "Station ID" "${cur_station_id:-${stack_station_id:-}}" true false)
update_url=$(prompt_value "Update manifest URL" "${cur_update_url:-https://raw.githubusercontent.com/alphaoflogic-ua/smart-home-updates/main/release.json}" true false)
check_interval=$(prompt_value "Check interval (minutes)" "${cur_interval:-60}" false false)
auto_update=$(prompt_value "Auto update (true/false)" "${cur_auto:-true}" false false)
agent_token="${cur_agent_token:-$(openssl rand -hex 16)}"

cat > "$AGENT_DEST/.env" <<EOF
STATION_ID='$station_id'
UPDATE_SERVER_URL='$update_url'
CHECK_INTERVAL_MINUTES='$check_interval'
AUTO_UPDATE='$auto_update'
BOOTSTRAP_ON_START='true'
COMPOSE_PROJECT_PATH='$DEPLOY_DIR'
COMPOSE_FILE='docker-compose.yml'
HEALTHCHECK_URL='${cur_healthcheck:-http://localhost:3000/health}'
DATA_DIR='$AGENT_DATA_DIR'
DOCKER_USERNAME='$docker_username'
DOCKER_TOKEN='$docker_token'
AGENT_API_TOKEN='$agent_token'
BACKEND_AGENT_TOKEN='${stack_agent_token:-$cur_backend_agent_token}'
BACKEND_URL='http://localhost:3000'
FIRMWARE_CACHE_DIR='$FIRMWARE_CACHE_DIR'
FIRMWARE_MANIFEST_URL='https://raw.githubusercontent.com/alphaoflogic-ua/smart-home-updates/main/firmware/manifest.json'
EOF

sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<EOF
[Unit]
Description=Station Agent — smart home auto-updater
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$AGENT_DEST
EnvironmentFile=$AGENT_DEST/.env
ExecStart=$AGENT_DEST/station-agent
Restart=always
RestartSec=15
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Seed current version so agent doesn't re-download on first check
RELEASE_JSON_URL=$(echo "$update_url" | sed 's/[[:space:]]*$//')
CURRENT_VER=$(curl -fsSL "$RELEASE_JSON_URL" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || true)
if [ -n "$CURRENT_VER" ]; then
  echo "$CURRENT_VER" | sudo -u "$REAL_USER" tee "$AGENT_DATA_DIR/current_version.txt" > /dev/null
  log "Seeded current version: $CURRENT_VER"
fi

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 3

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "Done. Station agent is running."
echo ""
sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
echo ""
echo "Open in browser:  http://${LOCAL_IP:-localhost}"
echo ""
echo "Useful commands:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  curl http://localhost:3001/status"