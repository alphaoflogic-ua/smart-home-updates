#!/usr/bin/env bash
set -euo pipefail

# Remove a Svaroh device-agent. Usage: reset-device-agent.sh [<device>] (default: camera).
# Touches only that agent's service — leaves the station and other services untouched.
# Set PURGE_DATA=1 to also delete the persisted config (re-provisions on reinstall).

DEVICE="${1:-${DEVICE:-camera}}"
AGENT="device-agent-${DEVICE}"
AGENT_DEST="${AGENT_DEST:-/opt/${AGENT}}"
DATA_DIR="${DATA_DIR:-/var/lib/${AGENT}}"
SERVICE_NAME="${AGENT}"

log() { echo "==> $*"; }

log "Stopping and disabling $SERVICE_NAME..."
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true

log "Removing service unit and binary..."
sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
sudo systemctl daemon-reload
sudo rm -rf "$AGENT_DEST"

if [ "${PURGE_DATA:-0}" = "1" ]; then
  log "Purging data dir $DATA_DIR..."
  sudo rm -rf "$DATA_DIR"
else
  log "Keeping data dir $DATA_DIR (set PURGE_DATA=1 to remove)."
fi

echo "Done. ${AGENT} removed."
