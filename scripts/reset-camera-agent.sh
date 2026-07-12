#!/usr/bin/env bash
set -euo pipefail

# Remove the Svaroh camera-agent. Touches only the camera-agent service —
# leaves the station and any other services untouched.
# Set PURGE_DATA=1 to also delete the persisted config (re-provisions on reinstall).

AGENT_DEST="${AGENT_DEST:-/opt/camera-agent}"
DATA_DIR="${DATA_DIR:-/var/lib/camera-agent}"
SERVICE_NAME="camera-agent"

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

echo "Done. camera-agent removed."
