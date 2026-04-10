#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/smart-home}"
NEEDS_REBOOT=false

echo "[1/8] Updating system packages..."
sudo apt update
sudo apt upgrade -y

echo "[2/8] Installing Docker Engine..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh

echo "[3/8] Setting hostname for mDNS discovery..."
STATION_HOSTNAME="${STATION_HOSTNAME:-smartstation}"
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$STATION_HOSTNAME" ]; then
  sudo hostnamectl set-hostname "$STATION_HOSTNAME"
  # Update /etc/hosts so sudo can resolve the new hostname
  if grep -q "$CURRENT_HOSTNAME" /etc/hosts; then
    sudo sed -i "s/$CURRENT_HOSTNAME/$STATION_HOSTNAME/g" /etc/hosts
  else
    echo "127.0.1.1	$STATION_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
  fi
  echo "Hostname set to $STATION_HOSTNAME (was $CURRENT_HOSTNAME)"
  echo "Devices will reach MQTT broker at ${STATION_HOSTNAME}.local"
else
  echo "Hostname already set to $STATION_HOSTNAME"
  if ! grep -q "$STATION_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1	$STATION_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    echo "Added $STATION_HOSTNAME to /etc/hosts"
  fi
fi

# Restart avahi so mDNS advertises the correct hostname
if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
  sudo systemctl restart avahi-daemon
  echo "Restarted avahi-daemon (mDNS: ${STATION_HOSTNAME}.local)"
fi

echo "[4/8] Installing Bluetooth and system dependencies..."
sudo apt install -y bluez util-linux rfkill dbus
# bluetoothd must be running — noble uses D-Bus/BlueZ for BLE operations
sudo systemctl enable bluetooth
sudo systemctl start bluetooth || true

echo "[5/8] Configuring Bluetooth on host..."

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

echo "[6/8] Installing Docker Compose plugin..."
sudo apt install -y docker-compose-plugin

echo "[7/8] Enabling Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "[8/8] Adding user to docker group..."
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