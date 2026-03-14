# Station Agent

Minimal update agent for Smart Home Station (Raspberry Pi, Docker Compose).

Внимание: начиная с этой версии station-agent запускается вне Docker (host‑mode) как системный сервис. Сервис `station-agent` удалён из `docker-compose.prod.yml`.

## Folder structure

```text
station-agent/
  src/
    server.js
    updater.js
    docker.js
    version.js
    healthcheck.js
    config.js
  package.json
  Dockerfile
```

## Установка в host‑mode (systemd)

1. Подготовить окружение на хосте

- Node.js >= 18 (рекомендуем 20+)
- Docker и `docker compose` доступны пользователю агента

2. Скопировать каталог `station-agent` на хост, например `/opt/station-agent`

3. Настройка окружения: скопируйте `station-agent/.env.example` в `/etc/station-agent.env` и заполните значения

Ключевые переменные:

- `STATION_ID`, `UPDATE_SERVER_URL`
- `COMPOSE_PROJECT_PATH` (путь к каталогу проекта с `docker-compose.prod.yml`)
- `HEALTHCHECK_URL` (URL, доступный с хоста, например `http://localhost:3000/health`)
- (опц.) `DOCKER_USERNAME`, `DOCKER_TOKEN` для приватных образов

4. Установка зависимостей и ручной запуск для проверки

```bash
cd /opt/station-agent
npm ci --omit=dev
env $(cat /etc/station-agent.env | xargs) node src/server.js
```

5. Автозапуск через systemd
   Создайте `/etc/systemd/system/station-agent.service`:

```ini
[Unit]
Description=Smart Home Station Agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/station-agent.env
WorkingDirectory=/opt/station-agent
ExecStart=/usr/bin/node /opt/station-agent/src/server.js
Restart=always
RestartSec=5
User=station
Group=station

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

Дайте права:

```bash
useradd -r -s /usr/sbin/nologin station || true
usermod -aG docker station
mkdir -p /var/lib/station-agent && chown -R station:station /var/lib/station-agent
systemctl daemon-reload && systemctl enable --now station-agent
```

Проверка:

```bash
journalctl -u station-agent -f
curl -s http://localhost:3001/status
```

## Пример `.env` для host‑mode

```dotenv
STATION_ID=5f3f8a7a-2f0f-45d8-9f48-89bb8a84a0f7
UPDATE_SERVER_URL=https://updates.example.com
CHECK_INTERVAL_MINUTES=30
COMPOSE_PROJECT_PATH=/app
COMPOSE_FILE=docker-compose.prod.yml
CURRENT_VERSION=1.0.0
AUTO_UPDATE=false
HEALTHCHECK_URL=http://backend:3000/health
# Optional: private registry auth (Docker Hub by default)
DOCKER_USERNAME=your_dockerhub_username
DOCKER_TOKEN=your_dockerhub_access_token
# DOCKER_REGISTRY=registry-1.docker.io
```

## API

- `GET /health`
- `GET /version`
- `GET /status`
- `POST /update`
- `POST /rollback`

## Example `curl`

```bash
curl -s http://localhost:3001/health
```

```bash
curl -s http://localhost:3001/version
```

```bash
curl -s http://localhost:3001/status
```

```bash
curl -s -X POST http://localhost:3001/update \
  -H 'Content-Type: application/json' \
  -d '{"version":"1.2.0"}'
```

```bash
curl -s -X POST http://localhost:3001/rollback
```

## Logged events

- `update_start`
- `docker_pull`
- `docker_restart`
- `healthcheck_passed`
- `healthcheck_failed`
- `rollback_started`
- `rollback_completed`
- `update_completed`

## Private Docker images

Если ваши образы приватные, агент может сам выполнить авторизацию в реестре перед `docker pull`.

- Задайте переменные окружения `DOCKER_USERNAME` и `DOCKER_TOKEN` (access token Docker Hub).
- Опционально укажите `DOCKER_REGISTRY` (по умолчанию Docker Hub, параметр можно не задавать).
- Агент попытается выполнить `docker login` и повторит `pull` один раз при ошибке авторизации.

Безопасность: токен не логируется — при ошибках выполнения команды он маскируется.
