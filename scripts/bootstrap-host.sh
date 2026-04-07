#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/smart-home}"
NEEDS_REBOOT=false

echo "[1/7] Updating system packages..."
sudo apt update
sudo apt upgrade -y

echo "[2/7] Installing Docker Engine..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh

echo "[3/7] Installing Bluetooth and system dependencies..."
sudo apt install -y bluez util-linux rfkill dbus
# bluetoothd must be running — noble uses D-Bus/BlueZ for BLE operations
sudo systemctl enable bluetooth
sudo systemctl start bluetooth || true

echo "[4/7] Configuring Bluetooth on host..."

# Re-enable built-in Bluetooth if it was previously disabled (e.g. for a USB dongle).
BOOT_CONFIG=""
for f in /boot/firmware/config.txt /boot/config.txt; do
  if [ -f "$f" ]; then
    BOOT_CONFIG="$f"
    break
  fi
done

if [ -n "$BOOT_CONFIG" ] && grep -q "^dtoverlay=disable-bt" "$BOOT_CONFIG"; then
  echo "Re-enabling onboard Bluetooth (removing dtoverlay=disable-bt from $BOOT_CONFIG)..."
  sudo sed -i '/^dtoverlay=disable-bt/d' "$BOOT_CONFIG"
  NEEDS_REBOOT=true
  echo "NOTE: Onboard BT will be enabled after reboot."
fi

if command -v rfkill >/dev/null 2>&1; then
  echo "Unblocking Bluetooth via rfkill..."
  sudo rfkill unblock bluetooth || true
fi

if [ -d "/sys/class/bluetooth/hci0" ]; then
  echo "Bluetooth adapter hci0 detected"
else
  echo "WARNING: Bluetooth adapter hci0 not detected. It should appear after reboot."
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

if [ "$NEEDS_REBOOT" = true ]; then
  echo
  echo "Bluetooth config changed. Rebooting in 5 seconds to apply..."
  echo "After reboot, run: ./scripts/deploy-station.sh"
  sleep 5
  sudo reboot
fi

echo "Starting a new shell with 'docker' group permissions..."
exec newgrp docker <<EOM
  echo "Groups updated. You can now run: ./scripts/deploy-station.sh"
  bash
EOM