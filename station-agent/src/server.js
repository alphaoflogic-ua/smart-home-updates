import http from 'node:http';
import { config } from './config.js';
import { StationUpdater } from './updater.js';
import { bootstrapStack } from './bootstrap.js';

const updater = new StationUpdater(config);

const sendJson = (res, statusCode, data) => {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
  });
  res.end(JSON.stringify(data));
};

const parseJsonBody = (req) =>
  new Promise((resolve, reject) => {
    let body = '';

    req.on('data', (chunk) => {
      body += chunk.toString('utf8');
      if (body.length > 1024 * 64) {
        reject(new Error('Payload too large'));
      }
    });

    req.on('end', () => {
      if (!body) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(body));
      } catch {
        reject(new Error('Invalid JSON body'));
      }
    });

    req.on('error', (error) => {
      reject(error);
    });
  });

const requireAuth = (req, res) => {
  const token = config.agentToken;
  if (!token) return true;
  const authHeader = req.headers['authorization'] || '';
  const provided = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : null;
  if (provided !== token) {
    sendJson(res, 401, { error: 'Unauthorized' });
    return false;
  }
  return true;
};

const handleRequest = async (req, res) => {
  const { method } = req;
  const url = new URL(req.url || '/', 'http://localhost');

  if (method === 'GET' && url.pathname === '/health') {
    sendJson(res, 200, { ok: true, service: 'station-agent' });
    return;
  }

  if (method === 'GET' && url.pathname === '/version') {
    const status = updater.getStatus();
    sendJson(res, 200, {
      currentVersion: status.currentVersion,
      latestVersion: status.latestVersion,
    });
    return;
  }

  if (method === 'GET' && url.pathname === '/status') {
    sendJson(res, 200, updater.getStatus());
    return;
  }

  if (method === 'POST' && url.pathname === '/update') {
    if (!requireAuth(req, res)) return;
    try {
      const body = await parseJsonBody(req);
      const result = await updater.update({ version: body.version });
      sendJson(res, 200, result);
    } catch (error) {
      const statusCode = error?.statusCode || 500;
      sendJson(res, statusCode, { error: error.message || 'Update failed' });
    }
    return;
  }

  if (method === 'POST' && url.pathname === '/rollback') {
    if (!requireAuth(req, res)) return;
    try {
      const result = await updater.rollback();
      sendJson(res, 200, result);
    } catch (error) {
      const statusCode = error?.statusCode || 500;
      sendJson(res, statusCode, { error: error.message || 'Rollback failed' });
    }
    return;
  }

  sendJson(res, 404, { error: 'Not found' });
};

const start = async () => {
  try {
    await updater.init();
    await bootstrapStack(config);
    updater.startPeriodicChecks();

    const server = http.createServer((req, res) => {
      handleRequest(req, res).catch((error) => {
        sendJson(res, 500, { error: error.message || 'Unhandled error' });
      });
    });

    server.listen(config.port, config.host, () => {
      console.log(
        JSON.stringify({
          time: new Date().toISOString(),
          event: 'station_agent_started',
          port: config.port,
          stationId: config.stationId,
        }),
      );
    });
  } catch (error) {
    console.error(
      JSON.stringify({
        time: new Date().toISOString(),
        event: 'station_agent_start_failed',
        error: error instanceof Error ? error.message : String(error),
      }),
    );
    process.exit(1);
  }
};

start();
