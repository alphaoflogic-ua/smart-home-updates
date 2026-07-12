#!/usr/bin/env bash
set -euo pipefail

# Remove a Svaroh device-agent. Run with no arg → pick from the agents actually
# installed under /opt/device-agent-*. Touches only that agent's service — leaves
# the station and other services untouched.
# Set PURGE_DATA=1 to also delete the persisted config (re-provisions on reinstall).

UPDATES_REPO="${UPDATES_REPO:-alphaoflogic-ua/smart-home-updates}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}"

DEVICE="${1:-${DEVICE:-}}"

# No device given → pick from installed agents. Needs a TTY — re-exec through
# /dev/tty when piped (curl | sudo bash), mirroring install-device-agent.sh.
if [ -z "$DEVICE" ]; then
  if [ ! -t 0 ] && [ -z "${_REEXEC:-}" ]; then
    TMP=$(mktemp)
    curl -fsSL "${RAW}/reset-device-agent.sh" -o "$TMP"
    _REEXEC=1 exec bash "$TMP" < /dev/tty
  fi
  INSTALLED=()
  for d in /opt/device-agent-*/; do
    [ -d "$d" ] || continue
    name="${d%/}"
    INSTALLED+=("${name##*/device-agent-}")
  done
  if [ "${#INSTALLED[@]}" -eq 0 ]; then
    echo "No device-agent installed under /opt." >&2
    exit 1
  elif [ "${#INSTALLED[@]}" -eq 1 ]; then
    DEVICE="${INSTALLED[0]}"
  else
    echo "Which device-agent to remove?"
    select d in "${INSTALLED[@]}"; do
      [ -n "$d" ] && DEVICE="$d" && break
    done
  fi
fi

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
