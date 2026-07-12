#!/usr/bin/env bash
set -euo pipefail

# Installer for a Svaroh device-agent (Raspberry Pi, arm64).
# Run with no arg → interactive menu of published agents (device-agents.json).
#   e.g.  curl -fsSL .../install-device-agent.sh | sudo bash
# Node.js is NOT needed — the agent ships as a single SEA binary.
#
# Optional env overrides: STATION_BASE_URL, EXTERNAL_ID, DATA_DIR.

# ── resolve real user (even when run via sudo) ────────────────────────────────
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="$USER"
fi

# ── config ────────────────────────────────────────────────────────────────────
UPDATES_REPO="${UPDATES_REPO:-alphaoflogic-ua/smart-home-updates}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}"

DEVICE="${1:-${DEVICE:-}}"

# No device given → pick from the published list (device-agents.json, written by CI
# from the agents/ folder names). Needs a TTY — re-exec through /dev/tty when piped.
if [ -z "$DEVICE" ]; then
  if [ ! -t 0 ] && [ -z "${_REEXEC:-}" ]; then
    TMP=$(mktemp)
    curl -fsSL "${RAW}/install-device-agent.sh" -o "$TMP"
    _REEXEC=1 exec bash "$TMP" < /dev/tty
  fi
  command -v curl >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y curl; }
  mapfile -t DEVICES < <(curl -fsSL "${RAW}/device-agents.json" | grep -oE '"[a-z0-9-]+"' | tr -d '"')
  if [ "${#DEVICES[@]}" -eq 0 ]; then
    echo "No device-agents published in ${UPDATES_REPO} yet." >&2
    exit 1
  fi
  echo "Which device-agent to install?"
  select d in "${DEVICES[@]}"; do
    [ -n "$d" ] && DEVICE="$d" && break
  done
fi

AGENT="device-agent-${DEVICE}"
BINARY_URL="${RAW}/${AGENT}/${AGENT}-linux-arm64"
OTA_MANIFEST_URL="${RAW}/${AGENT}/manifest.json"

AGENT_DEST="${AGENT_DEST:-/opt/${AGENT}}"
DATA_DIR="${DATA_DIR:-/var/lib/${AGENT}}"
SERVICE_NAME="$AGENT"

log() { echo "==> $*"; }

# ── [1/3] prerequisites ───────────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y curl
fi

# The binary is linux-arm64 — refuse a 32-bit OS (common on Pi3 with 32-bit Raspbian).
ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "ERROR: ${AGENT} binary is linux-arm64, but this host reports '$ARCH'." >&2
  echo "       Install a 64-bit OS (uname -m must be aarch64)." >&2
  exit 1
fi

# The camera agent shells out to gstreamer (HW H264 encode) reading the IMX290 CSI
# sensor via libcamera. Install the runtime pieces; a missing package is a warning,
# not a hard failure (names vary across Raspberry Pi OS releases).
if [ "$DEVICE" = "camera" ]; then
  log "Installing gstreamer + libcamera for the camera pipeline..."
  sudo apt-get update -qq
  sudo apt-get install -y \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-libcamera \
    libcamera-tools ||
    echo "WARN: some gstreamer/libcamera packages were not installed — verify the camera pipeline manually."

  # Enable the CSI sensor. IMX290 is a third-party sensor, so camera_auto_detect
  # (official Pi cameras only) won't bring it up — it needs an explicit overlay and
  # a reboot. Override for a different board via CAMERA_OVERLAY / CAMERA_CLOCK.
  CAMERA_OVERLAY="${CAMERA_OVERLAY:-imx290}"
  CAMERA_CLOCK="${CAMERA_CLOCK:-37125000}"
  CONFIG_TXT="/boot/firmware/config.txt"
  [ -f "$CONFIG_TXT" ] || CONFIG_TXT="/boot/config.txt"
  OVERLAY_LINE="dtoverlay=${CAMERA_OVERLAY},clock-frequency=${CAMERA_CLOCK}"
  if [ -f "$CONFIG_TXT" ] && ! grep -qxF "$OVERLAY_LINE" "$CONFIG_TXT"; then
    log "Enabling ${CAMERA_OVERLAY} sensor overlay in ${CONFIG_TXT} (reboot needed)..."
    sudo cp "$CONFIG_TXT" "${CONFIG_TXT}.svaroh.bak"
    sudo sed -i 's/^camera_auto_detect=1/camera_auto_detect=0/' "$CONFIG_TXT"
    echo "$OVERLAY_LINE" | sudo tee -a "$CONFIG_TXT" > /dev/null
    CAMERA_REBOOT_REQUIRED=1
  fi
fi

# ── [1/3] install binary ──────────────────────────────────────────────────────
log "[1/3] Installing ${AGENT} binary to $AGENT_DEST..."
sudo mkdir -p "$AGENT_DEST" "$DATA_DIR"
curl -fsSL "$BINARY_URL" | sudo tee "$AGENT_DEST/${AGENT}" > /dev/null
sudo chmod +x "$AGENT_DEST/${AGENT}"
sudo chown -R "$REAL_USER":"$REAL_USER" "$AGENT_DEST" "$DATA_DIR"

# ── [2/3] write env ───────────────────────────────────────────────────────────
log "[2/3] Writing config to $AGENT_DEST/.env..."
{
  echo "DATA_DIR='$DATA_DIR'"
  echo "OTA_MANIFEST_URL='$OTA_MANIFEST_URL'"
  if [ -n "${STATION_BASE_URL:-}" ]; then echo "STATION_BASE_URL='$STATION_BASE_URL'"; fi
  if [ -n "${EXTERNAL_ID:-}" ]; then echo "EXTERNAL_ID='$EXTERNAL_ID'"; fi
} | sudo tee "$AGENT_DEST/.env" > /dev/null

# ── [3/3] systemd service ─────────────────────────────────────────────────────
log "[3/3] Installing systemd service..."
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Svaroh device-agent (${DEVICE})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$AGENT_DEST
EnvironmentFile=$AGENT_DEST/.env
ExecStart=$AGENT_DEST/${AGENT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

sleep 2
echo ""
echo "Done. ${AGENT} is running."
echo ""
sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
echo ""
echo "Station:      ${STATION_BASE_URL:-http://svaroh.local (mDNS default)}"
echo "Data dir:     $DATA_DIR"
echo "Logs:         sudo journalctl -u $SERVICE_NAME -f"
echo "Status:       systemctl status $SERVICE_NAME"
echo ""
echo "Auto-update:  ON — the agent checks for a newer release on boot and hourly,"
echo "              then updates itself and restarts (no reinstall needed)."
echo "              Force a re-check now:  sudo systemctl restart $SERVICE_NAME"
echo "              Custom manifest:       set OTA_MANIFEST_URL in $AGENT_DEST/.env"
echo ""
echo "Reinstall:    curl -fsSL ${RAW}/install-device-agent.sh | sudo bash   (pick from menu)"
echo "Remove:       curl -fsSL ${RAW}/reset-device-agent.sh   | sudo bash   (pick from menu)"
echo "              (add PURGE_DATA=1 to also drop enrollment config)"

# The sensor overlay only takes effect after a reboot; offer it (interactive only).
if [ "${CAMERA_REBOOT_REQUIRED:-0}" = "1" ]; then
  echo ""
  echo "⚠  Camera sensor overlay added — a REBOOT is required for the sensor to appear."
  echo "   After reboot:  rpicam-hello --list-cameras   should list it; the agent streams on demand."
  if [ -t 0 ]; then
    read -r -p "Reboot now? [y/N] " REBOOT_ANS || REBOOT_ANS=""
    case "$REBOOT_ANS" in
      [yY]*) sudo reboot ;;
      *) echo "   Reboot later:  sudo reboot" ;;
    esac
  else
    echo "   Reboot to finish:  sudo reboot"
  fi
fi
