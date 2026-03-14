import { spawn } from 'node:child_process';
import { dockerLogin, dockerComposePull, dockerComposeUp } from './docker.js';

const log = (event, details = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), event, ...details }));

/**
 * Returns true if at least one service from the compose stack is running.
 */
const isStackRunning = (config) =>
  new Promise((resolve) => {
    const args = [
      'compose',
      '-f',
      `${config.composeProjectPath}/${config.composeFile}`,
      'ps',
      '--services',
      '--filter',
      'status=running',
    ];

    const child = spawn('docker', args, {
      cwd: config.composeProjectPath,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.on('close', () => {
      resolve(stdout.trim().length > 0);
    });
    child.on('error', () => resolve(false));
  });

/**
 * Bootstrap the station stack on agent startup.
 * If BOOTSTRAP_ON_START=true and the stack is not running — pull images and start it.
 */
export const bootstrapStack = async (config) => {
  if (!config.bootstrapOnStart) {
    log('bootstrap_skipped', { reason: 'BOOTSTRAP_ON_START is not enabled' });
    return;
  }

  log('bootstrap_check');

  const running = await isStackRunning(config);

  if (running) {
    log('bootstrap_skipped', { reason: 'stack already running' });
    return;
  }

  log('bootstrap_start', { composeProjectPath: config.composeProjectPath });

  try {
    await dockerLogin(config);
  } catch {
    // ignore — may be public images
  }

  log('bootstrap_pull');
  await dockerComposePull(config, config.services);

  log('bootstrap_up');
  await dockerComposeUp(config, config.services);

  log('bootstrap_done');
};
