#!/usr/bin/env bash
set -euo pipefail

# Non-interactive installer for the Svaroh camera-agent (Raspberry Pi, arm64).
# Node.js is NOT needed — the agent ships as a single SEA binary.
#
# Zero prompts. Optional overrides via environment:
#   STATION_BASE_URL   explicit station URL (default: mDNS http://svaroh.local)
#   EXTERNAL_ID        pin device identity (default: /proc/cpuinfo serial)
#   DATA_DIR           persisted config dir (default: /var/lib/camera-agent)

# ── resolve real user (even when run via sudo) ────────────────────────────────
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="$USER"
fi

# ── config ────────────────────────────────────────────────────────────────────
UPDATES_REPO="${UPDATES_REPO:-alphaoflogic-ua/smart-home-updates}"
BRANCH="${BRANCH:-main}"
BINARY_URL="https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}/camera-agent/camera-agent-linux-arm64"

AGENT_DEST="${AGENT_DEST:-/opt/camera-agent}"
DATA_DIR="${DATA_DIR:-/var/lib/camera-agent}"
SERVICE_NAME="camera-agent"

log() { echo "==> $*"; }

# ── [1/3] prerequisites ───────────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y curl
fi

# The binary is linux-arm64 — refuse a 32-bit OS (common on Pi3 with 32-bit Raspbian).
ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "ERROR: camera-agent binary is linux-arm64, but this host reports '$ARCH'." >&2
  echo "       Install a 64-bit OS (uname -m must be aarch64)." >&2
  exit 1
fi

# ── [1/3] install binary ──────────────────────────────────────────────────────
log "[1/3] Installing camera-agent binary to $AGENT_DEST..."
sudo mkdir -p "$AGENT_DEST" "$DATA_DIR"
curl -fsSL "$BINARY_URL" | sudo tee "$AGENT_DEST/camera-agent" > /dev/null
sudo chmod +x "$AGENT_DEST/camera-agent"
sudo chown -R "$REAL_USER":"$REAL_USER" "$AGENT_DEST" "$DATA_DIR"

# ── [2/3] write env ───────────────────────────────────────────────────────────
log "[2/3] Writing config to $AGENT_DEST/.env..."
{
  echo "DATA_DIR='$DATA_DIR'"
  if [ -n "${STATION_BASE_URL:-}" ]; then echo "STATION_BASE_URL='$STATION_BASE_URL'"; fi
  if [ -n "${EXTERNAL_ID:-}" ]; then echo "EXTERNAL_ID='$EXTERNAL_ID'"; fi
} | sudo tee "$AGENT_DEST/.env" > /dev/null

# ── [3/3] systemd service ─────────────────────────────────────────────────────
log "[3/3] Installing systemd service..."
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Svaroh Camera Agent (IMX290)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$AGENT_DEST
EnvironmentFile=$AGENT_DEST/.env
ExecStart=$AGENT_DEST/camera-agent
Restart=on-failure
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
echo "Done. camera-agent is running."
echo ""
sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
echo ""
echo "Station:  ${STATION_BASE_URL:-http://svaroh.local (mDNS default)}"
echo "Logs:     sudo journalctl -u $SERVICE_NAME -f"
echo "Remove:   curl -fsSL https://raw.githubusercontent.com/${UPDATES_REPO}/${BRANCH}/reset-camera-agent.sh | sudo bash"
