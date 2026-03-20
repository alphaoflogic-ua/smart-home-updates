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

# Disable built-in Bluetooth so the USB dongle becomes hci0.
# This avoids issues with the RPi's onboard BT and ensures noble always binds
# to the external adapter at a stable hci0 index.
BOOT_CONFIG=""
for f in /boot/firmware/config.txt /boot/config.txt; do
  if [ -f "$f" ]; then
    BOOT_CONFIG="$f"
    break
  fi
done

if [ -n "$BOOT_CONFIG" ]; then
  if ! grep -q "^dtoverlay=disable-bt" "$BOOT_CONFIG"; then
    echo "Disabling onboard Bluetooth via $BOOT_CONFIG..."
    echo "dtoverlay=disable-bt" | sudo tee -a "$BOOT_CONFIG" >/dev/null
    NEEDS_REBOOT=true
    echo "NOTE: Onboard BT will be disabled after reboot."
  else
    echo "Onboard Bluetooth already disabled in $BOOT_CONFIG"
  fi
else
  echo "WARNING: Could not find boot config file to disable onboard Bluetooth"
fi

if command -v rfkill >/dev/null 2>&1; then
  echo "Unblocking Bluetooth via rfkill..."
  sudo rfkill unblock bluetooth || true
fi

# BlueZ manages the adapter via D-Bus — noble connects through bluetoothd.
if [ -d "/sys/class/bluetooth/hci0" ]; then
  echo "Bluetooth adapter hci0 detected"
else
  echo "WARNING: Bluetooth adapter hci0 not detected! Please ensure a USB Bluetooth dongle is plugged in."
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
  echo "Onboard Bluetooth was disabled. Rebooting in 5 seconds so the USB dongle becomes hci0..."
  echo "After reboot, run: ./scripts/deploy-station.sh"
  sleep 5
  sudo reboot
fi

echo "Starting a new shell with 'docker' group permissions..."
exec newgrp docker <<EOM
  echo "Groups updated. You can now run: ./scripts/deploy-station.sh"
  bash
EOM