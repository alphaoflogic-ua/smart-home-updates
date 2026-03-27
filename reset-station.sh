#!/usr/bin/env bash
set -euo pipefail

if [ ! -t 0 ] && [ -z "${_RESET_REEXEC:-}" ]; then
  TMP=$(mktemp /tmp/reset-station.XXXXXX.sh)
  curl -fsSL "https://raw.githubusercontent.com/alphaoflogic-ua/smart-home-updates/main/reset-station.sh" -o "$TMP"
  chmod +x "$TMP"
  _RESET_REEXEC=1 exec bash "$TMP" "$@" < /dev/tty
fi

# ── resolve real user (even when run via sudo) ────────────────────────────────
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
  REAL_HOME=$(eval echo "~$SUDO_USER")
else
  REAL_USER="$USER"
  REAL_HOME="$HOME"
fi

AGENT_DEST="${AGENT_DEST:-/opt/station-agent}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/var/lib/station-agent}"
DEPLOY_DIR="${DEPLOY_DIR:-${REAL_HOME}/smart-home}"
FIRMWARE_CACHE_DIR="${REAL_HOME}/firmware-cache"
SERVICE_NAME="station-agent"

echo "This will remove:"
echo "  - systemd service: $SERVICE_NAME"
echo "  - agent files:     $AGENT_DEST"
echo "  - agent data:      $AGENT_DATA_DIR"
echo "  - stack:           $DEPLOY_DIR (docker compose down -v)"
echo "  - firmware cache:  $FIRMWARE_CACHE_DIR"
echo "  - docker images:   all unused images"
echo ""
read -rp "Continue? [y/N]: " confirm < /dev/tty
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# stop agent
echo "Stopping agent..."
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
sudo systemctl daemon-reload

# remove agent files
echo "Removing agent files..."
sudo rm -rf "$AGENT_DEST"
sudo rm -rf "$AGENT_DATA_DIR"
sudo rm -rf "$FIRMWARE_CACHE_DIR"

# stop and remove stack
if [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
  echo "Stopping stack..."
  sudo docker compose -f "$DEPLOY_DIR/docker-compose.yml" down -v 2>/dev/null || true
fi

echo "Removing deployment dir..."
sudo rm -rf "$DEPLOY_DIR"

# clean docker
echo "Pruning docker images..."
sudo docker system prune -af 2>/dev/null || true

echo ""
echo "Done. Ready for fresh install:"
echo "  curl -fsSL https://raw.githubusercontent.com/alphaoflogic-ua/smart-home-updates/main/install-agent.sh | sudo bash"