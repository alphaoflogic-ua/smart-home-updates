#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/smart-home}"

echo "[1/7] Updating system packages..."
sudo apt update
sudo apt upgrade -y

echo "[2/7] Installing Docker Engine..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh

echo "[3/7] Installing Bluetooth and system dependencies..."
sudo apt install -y bluez util-linux rfkill
sudo systemctl enable bluetooth
sudo systemctl start bluetooth

echo "[4/7] Configuring Bluetooth on host..."
if command -v rfkill >/dev/null 2>&1; then
  echo "Unblocking Bluetooth via rfkill..."
  sudo rfkill unblock bluetooth || true
fi

if command -v hciconfig >/dev/null 2>&1; then
  echo "Bringing hci0 up..."
  sudo hciconfig hci0 up || true
fi

if [ -d "/sys/class/bluetooth/hci0" ]; then
  echo "Bluetooth adapter hci0 detected"
else
  echo "WARNING: Bluetooth adapter hci0 not detected! Please ensure a Bluetooth adapter is plugged in."
fi

echo "[5/7] Installing Docker Compose plugin..."
sudo apt install -y docker-compose-plugin

echo "[6/7] Enabling Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "[7/7] Adding user to docker group..."
sudo usermod -aG docker "$USER"
echo "NOTE: Group changes will be applied in the next step via 'newgrp docker'"

echo
echo "Preparing deployment directory..."
sudo mkdir -p "$DEPLOY_DIR"
sudo chown -R "$USER":"$USER" "$DEPLOY_DIR"

echo
echo "Versions:"
docker --version || true
docker compose version || true
bluetoothctl --version || true

echo
echo "Host bootstrap completed."
echo "Starting a new shell with 'docker' group permissions..."
exec newgrp docker <<EOM
  echo "Groups updated. You can now run: ./scripts/deploy-station.sh"
  bash
EOM