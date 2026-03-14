import path from 'node:path';

const toBoolean = (value, fallback = false) => {
  if (value === undefined) return fallback;
  return value === 'true' || value === true;
};

const toPositiveInteger = (value, fallback) => {
  const parsed = Number.parseInt(value ?? '', 10);
  if (Number.isNaN(parsed) || parsed <= 0) return fallback;
  return parsed;
};

const expandHome = (p) =>
  p ? p.replace(/^~(?=$|\/|\\)/, process.env.HOME || '') : p;

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
};

const base = {
  port: 3001,
  checkIntervalMinutes: 60,
  composeProjectPath: '~/smart-home',
  composeFile: 'docker-compose.yml',
  currentVersionDefault: '1.0.0',
  autoUpdate: true,
  healthcheckUrl: 'http://localhost/api/health',
  stabilizationSeconds: 45,
  requestTimeoutMs: 10000,
  dataDir: '~/station-agent-data',
  services: ['backend', 'frontend'],
  containerNames: {
    backend: 'smart-home-backend',
    frontend: 'smart-home-frontend',
  },
};

export const config = {
  port: Number.parseInt(process.env.PORT ?? base.port, 10),
  stationId: required('STATION_ID'),
  updateServerUrl: required('UPDATE_SERVER_URL').replace(/\/$/, ''),
  checkIntervalMinutes: toPositiveInteger(
    process.env.CHECK_INTERVAL_MINUTES,
    base.checkIntervalMinutes,
  ),
  composeProjectPath: expandHome(process.env.COMPOSE_PROJECT_PATH || base.composeProjectPath),
  composeFile: process.env.COMPOSE_FILE || base.composeFile,
  currentVersionDefault: process.env.CURRENT_VERSION || base.currentVersionDefault,
  autoUpdate: toBoolean(process.env.AUTO_UPDATE, base.autoUpdate),
  healthcheckUrl: process.env.HEALTHCHECK_URL || base.healthcheckUrl,
  stabilizationSeconds: toPositiveInteger(
    process.env.STABILIZATION_SECONDS,
    base.stabilizationSeconds,
  ),
  requestTimeoutMs: toPositiveInteger(process.env.REQUEST_TIMEOUT_MS, base.requestTimeoutMs),
  dataDir: expandHome(process.env.DATA_DIR || base.dataDir),
  services: Array.isArray(base.services) ? base.services : ['backend', 'frontend'],
  containerNames: {
    backend:
      process.env.BACKEND_CONTAINER_NAME || base.containerNames?.backend || 'smart-home-backend',
    frontend:
      process.env.FRONTEND_CONTAINER_NAME || base.containerNames?.frontend || 'smart-home-frontend',
  },
  dockerAuth: {
    username: process.env.DOCKER_USERNAME || '',
    token: process.env.DOCKER_TOKEN || '',
    registry: process.env.DOCKER_REGISTRY || '',
  },
  host: process.env.HOST || '0.0.0.0',
  agentToken: process.env.AGENT_TOKEN || null,
  bootstrapOnStart: toBoolean(process.env.BOOTSTRAP_ON_START, false),
};

config.rollbackFilePath = path.join(config.dataDir, 'rollback.json');
config.currentVersionFilePath = path.join(config.dataDir, 'current_version.txt');
config.overrideComposeFilePath = path.join(config.dataDir, 'compose.rollback.override.yml');
config.updateOverrideFilePath = path.join(config.dataDir, 'compose.update.override.yml');
