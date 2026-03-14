import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';

const REPO = 'andriicode/smart-home';
const BRANCH = 'main';
const DEPLOYMENT_DIR = process.env.COMPOSE_PROJECT_PATH || path.join(process.env.HOME || '~', 'smart-home');

const DEPLOYMENT_FILES = [
  'deployment/raspberry-standalone/docker-compose.yml',
  'deployment/raspberry-standalone/docker-compose.prod.yml',
  'deployment/raspberry-standalone/scripts/bootstrap-host.sh',
  'deployment/raspberry-standalone/scripts/deploy-station.sh',
  'deployment/raspberry-standalone/nginx/certs/.gitkeep',
];

const log = (event, details = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), event, ...details }));

const rawUrl = (filePath) =>
  `https://raw.githubusercontent.com/${REPO}/${BRANCH}/${filePath}`;

const downloadFile = async (filePath, destDir) => {
  const url = rawUrl(filePath);
  const fileName = path.basename(filePath);
  const subDir = path.dirname(filePath).replace('deployment/raspberry-standalone', '').replace(/^\//, '');
  const destPath = path.join(destDir, subDir, fileName);

  await fs.mkdir(path.dirname(destPath), { recursive: true });

  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to download ${url}: ${res.status}`);
  const text = await res.text();
  await fs.writeFile(destPath, text, 'utf8');
  return destPath;
};

const runScript = (scriptPath, cwd) =>
  new Promise((resolve, reject) => {
    log('run_script', { script: scriptPath });
    const child = spawn('bash', [scriptPath], {
      cwd,
      stdio: 'inherit', // interactive — pass through stdin/stdout/stderr
      env: process.env,
    });
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`Script ${scriptPath} exited with code ${code}`));
      } else {
        resolve();
      }
    });
    child.on('error', reject);
  });

const isDockerInstalled = () =>
  new Promise((resolve) => {
    const child = spawn('docker', ['--version'], { stdio: 'ignore' });
    child.on('close', (code) => resolve(code === 0));
    child.on('error', () => resolve(false));
  });

/**
 * First-time setup:
 * 1. Download deployment files from GitHub
 * 2. Run bootstrap-host.sh if Docker is not installed
 * 3. Run deploy-station.sh if .env is not configured
 */
export const runSetupIfNeeded = async () => {
  const envPath = path.join(DEPLOYMENT_DIR, '.env');
  const composePath = path.join(DEPLOYMENT_DIR, 'docker-compose.yml');

  // If already set up — skip
  if (existsSync(envPath) && existsSync(composePath)) {
    log('setup_skipped', { reason: 'already configured', deploymentDir: DEPLOYMENT_DIR });
    return DEPLOYMENT_DIR;
  }

  log('setup_start', { deploymentDir: DEPLOYMENT_DIR });

  // Download deployment files
  log('setup_download', { repo: REPO, branch: BRANCH });
  for (const file of DEPLOYMENT_FILES) {
    if (file.endsWith('.gitkeep')) {
      const destDir = path.join(DEPLOYMENT_DIR, 'nginx/certs');
      await fs.mkdir(destDir, { recursive: true });
      continue;
    }
    await downloadFile(file, DEPLOYMENT_DIR);
    log('setup_downloaded', { file });
  }

  // Make scripts executable
  const scriptsDir = path.join(DEPLOYMENT_DIR, 'scripts');
  await fs.chmod(path.join(scriptsDir, 'bootstrap-host.sh'), 0o755);
  await fs.chmod(path.join(scriptsDir, 'deploy-station.sh'), 0o755);

  // Bootstrap Docker if needed
  const dockerReady = await isDockerInstalled();
  if (!dockerReady) {
    log('setup_bootstrap_host');
    await runScript(path.join(scriptsDir, 'bootstrap-host.sh'), DEPLOYMENT_DIR);
  } else {
    log('setup_docker_ok');
  }

  // Interactive station setup
  log('setup_deploy_station');
  await runScript(path.join(scriptsDir, 'deploy-station.sh'), DEPLOYMENT_DIR);

  log('setup_done', { deploymentDir: DEPLOYMENT_DIR });
  return DEPLOYMENT_DIR;
};
