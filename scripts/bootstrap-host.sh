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
sudo apt install -y bluez util-linux rfkill
# bluetoothd is NOT started — noble (inside Docker) uses raw HCI socket directly
# and bluetoothd interferes with BLE connect and GATT operations
sudo systemctl disable bluetooth || true
sudo systemctl stop bluetooth || true

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

# noble uses HCI_CHANNEL_USER inside Docker, which requires hci0 to be DOWN on the host.
# In HCI_CHANNEL_USER mode, noble fully owns the HCI device and initialises it itself
# via HCI Reset — the kernel sends no automatic HCI commands (e.g. LE Read Remote Used Features)
# that would otherwise delay GATT by ~288ms and cause ESP32 provisioning to time out.
# Remove any legacy hci0-up.service that brings the adapter up (this would conflict).
if systemctl is-enabled hci0-up.service >/dev/null 2>&1; then
  echo "Disabling legacy hci0-up.service (incompatible with HCI_CHANNEL_USER)..."
  sudo systemctl disable hci0-up.service || true
  sudo systemctl stop hci0-up.service || true
fi
sudo rm -f /etc/systemd/system/hci0-up.service
sudo systemctl daemon-reload

# Ensure hci0 is DOWN so noble can claim it via HCI_CHANNEL_USER
if command -v hciconfig >/dev/null 2>&1; then
  echo "Ensuring hci0 is down (noble will initialise it)..."
  sudo hciconfig hci0 down 2>/dev/null || true
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