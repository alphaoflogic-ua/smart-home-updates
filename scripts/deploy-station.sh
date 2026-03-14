#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Run scripts/bootstrap-host.sh first."
  exit 1
fi

if ! docker ps >/dev/null 2>&1; then
  echo "Permission denied while trying to connect to the Docker daemon."
  echo "Please run: newgrp docker"
  echo "Or try running this script with sudo."
  exit 1
fi

env_current() {
  local key="$1"
  if [ -f ".env" ]; then
    grep -m1 "^${key}=" .env | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true
  fi
}

prompt_value() {
  local key="$1"
  local prompt="$2"
  local default="$3"
  local required="$4"
  local secret="${5:-false}"
  local value=""

  while true; do
    if [ "$secret" = "true" ]; then
      if [ -n "$default" ]; then
        printf "%s [press Enter to keep current]: " "$prompt" >&2
      else
        printf "%s: " "$prompt" >&2
      fi
      # Use read -rs to hide password input
      read -rs value
      echo >&2
      if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
      fi
    else
      if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " value
      else
        read -rp "$prompt: " value
      fi
      if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
      fi
    fi

    # Trim leading/trailing whitespace
    value=$(echo "$value" | xargs)

    if [ "$required" = "true" ] && [ -z "$value" ]; then
      echo "Value is required." >&2
      continue
    fi

    printf "%s" "$value"
    return 0
  done
}

# Static UUIDs for provisioning - do not change these as they are matched in firmware
PROVISIONING_SERVICE_UUID='12345678-1234-1234-1234-1234567890ab'
PROVISIONING_CHARACTERISTIC_UUID='abcdefab-1234-5678-9abc-def012345678'

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback to a simpler random string if no UUID generator exists
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8
    echo -n "-"
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 4
    echo -n "-4"
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 3
    echo -n "-a"
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 3
    echo -n "-"
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 12
    echo
  fi
}

generate_secret() {
  local length="${1:-32}"
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
  echo
}

get_local_ip() {
  local ip
  # Try to get the IP used for external traffic (default gateway route)
  ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)

  # Fallback to hostname -I if ip route failed
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi

  # Last fallback to localhost if everything fails
  if [ -z "$ip" ]; then
    ip="127.0.0.1"
  fi
  echo "$ip"
}

get_or_generate() {
  local key="$1"
  local default="$2"
  local type="${3:-default}" # default, secret, uuid
  local value
  value=$(env_current "$key")

  if [ -z "$value" ]; then
    case "$type" in
      secret)
        value=$(generate_secret 32)
        ;;
      uuid)
        value=$(generate_uuid)
        ;;
      *)
        value="$default"
        ;;
    esac
  fi
  echo "$value"
}

echo "Configuration (Wi-Fi settings are interactive)"

# Logic to determine actual IPs before environment generation
actual_ip=$(get_local_ip)

station_id=$(get_or_generate "STATION_ID" "" "uuid")
db_user=$(get_or_generate "DB_USER" "smart_home_app")
db_password=$(get_or_generate "DB_PASSWORD" "" "secret")
db_name=$(get_or_generate "DB_NAME" "smart_home_app")
mqtt_user=$(get_or_generate "MQTT_USER" "station_backend_app")
mqtt_password=$(get_or_generate "MQTT_PASSWORD" "" "secret")
jwt_secret=$(get_or_generate "JWT_SECRET" "" "secret")
jwt_refresh_secret=$(get_or_generate "JWT_REFRESH_SECRET" "" "secret")
jwt_expires_in=$(get_or_generate "JWT_EXPIRES_IN" "1h")
jwt_refresh_expires_in=$(get_or_generate "JWT_REFRESH_EXPIRES_IN" "7d")

provisioning_wifi_ssid=$(prompt_value "PROVISIONING_WIFI_SSID" "Provisioning Wi-Fi SSID" "$(env_current PROVISIONING_WIFI_SSID)" false false)
provisioning_wifi_password=$(prompt_value "PROVISIONING_WIFI_PASSWORD" "Provisioning Wi-Fi password" "$(env_current PROVISIONING_WIFI_PASSWORD)" false true)

provisioning_scan_all=$(get_or_generate "PROVISIONING_SCAN_ALL" "false")
provisioning_allow_nameless=$(get_or_generate "PROVISIONING_ALLOW_NAMELESS" "true")
backend_public_url=$(get_or_generate "BACKEND_PUBLIC_URL" "http://$actual_ip:3000")
mqtt_public_host=$(get_or_generate "MQTT_PUBLIC_HOST" "$actual_ip")

cat > .env <<EOF
STATION_ID='$station_id'
DB_USER='$db_user'
DB_PASSWORD='$db_password'
DB_NAME='$db_name'
MQTT_USER='$mqtt_user'
MQTT_PASSWORD='$mqtt_password'
JWT_SECRET='$jwt_secret'
JWT_REFRESH_SECRET='$jwt_refresh_secret'
JWT_EXPIRES_IN='$jwt_expires_in'
JWT_REFRESH_EXPIRES_IN='$jwt_refresh_expires_in'
PROVISIONING_WIFI_SSID='$provisioning_wifi_ssid'
PROVISIONING_WIFI_PASSWORD='$provisioning_wifi_password'
PROVISIONING_SCAN_ALL='$provisioning_scan_all'
PROVISIONING_ALLOW_NAMELESS='$provisioning_allow_nameless'
PROVISIONING_SERVICE_UUID='$PROVISIONING_SERVICE_UUID'
PROVISIONING_CHARACTERISTIC_UUID='$PROVISIONING_CHARACTERISTIC_UUID'
BACKEND_PUBLIC_URL='$backend_public_url'
MQTT_PUBLIC_HOST='$mqtt_public_host'
EOF

echo "Saved configuration to .env"

echo "Starting standalone stack..."
docker compose up -d

echo "Waiting for backend container..."
for _ in {1..30}; do
  if docker ps --format '{{.Names}}' | grep -q '^smart-home-backend$'; then
    break
  fi
  sleep 2
done

echo "Smoke check (waiting for backend to be ready)..."
READY=0
for i in {1..30}; do
  if docker exec smart-home-backend node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    READY=1
    break
  fi
  echo "  attempt $i/30..."
  sleep 5
done

if [ "$READY" -eq 0 ]; then
  echo "Warning: backend did not respond in time. Check logs: docker compose logs backend"
fi

echo "Done."
echo "Open UI: http://$(get_local_ip)/"
echo "Check status: docker compose ps"
