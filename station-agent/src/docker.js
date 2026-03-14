import fs from 'node:fs/promises';
import { spawn } from 'node:child_process';

const redact = (text, redactList = []) => {
  if (!text || redactList.length === 0) return text;
  let out = text;
  for (const r of redactList) {
    if (!r) continue;
    const safe = typeof r === 'string' ? r : String(r);
    if (safe.length > 0) {
      // replace all occurrences of the secret with ******
      out = out.split(safe).join('******');
    }
  }
  return out;
};

const run = ({ command, args, cwd, timeoutMs = 0, redactArgsIndices = [] }) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let timeoutId;

    if (timeoutMs > 0) {
      timeoutId = setTimeout(() => {
        child.kill('SIGTERM');
        reject(new Error(`Command timed out after ${timeoutMs}ms: ${command} ${args.join(' ')}`));
      }, timeoutMs);
    }

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    child.on('error', (error) => {
      if (timeoutId) {
        clearTimeout(timeoutId);
      }
      reject(error);
    });

    child.on('close', (code) => {
      if (timeoutId) {
        clearTimeout(timeoutId);
      }

      if (code !== 0) {
        const secrets = redactArgsIndices
          .filter((i) => typeof i === 'number' && i >= 0 && i < args.length)
          .map((i) => args[i]);
        const safeCmd = `${command} ${args
          .map((a, i) => (redactArgsIndices.includes(i) ? '******' : a))
          .join(' ')}`;
        const safeOutput = redact(stderr || stdout, secrets);
        const err = new Error(`Command failed (${code}): ${safeCmd}\n${safeOutput}`);
        reject(err);
        return;
      }

      resolve({ stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });

const composeBaseArgs = (config) => [
  'compose',
  '-f',
  `${config.composeProjectPath}/${config.composeFile}`,
];

const composeWithRollbackOverrideArgs = (config) => [
  ...composeBaseArgs(config),
  '-f',
  config.overrideComposeFilePath,
];

const composeWithUpdateOverrideArgs = (config) => [
  ...composeBaseArgs(config),
  '-f',
  config.updateOverrideFilePath,
];

export const dockerComposePull = async (config, services = []) => {
  const args = [...composeBaseArgs(config), 'pull', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const dockerComposeUp = async (config, services = []) => {
  const args = [...composeBaseArgs(config), 'up', '-d', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const dockerComposePullRollback = async (config, services = []) => {
  const args = [...composeWithRollbackOverrideArgs(config), 'pull', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const dockerComposeUpRollback = async (config, services = []) => {
  const args = [...composeWithRollbackOverrideArgs(config), 'up', '-d', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const getContainerImage = async (containerName) => {
  const args = ['inspect', '--format', '{{.Config.Image}}', containerName];
  const { stdout } = await run({ command: 'docker', args });
  return stdout;
};

export const getCurrentImages = async (config) => {
  const backendImage = await getContainerImage(config.containerNames.backend);
  const frontendImage = await getContainerImage(config.containerNames.frontend);

  return {
    backend: backendImage,
    frontend: frontendImage,
  };
};

export const dockerComposePullUpdate = async (config, services = []) => {
  const args = [...composeWithUpdateOverrideArgs(config), 'pull', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const dockerComposeUpUpdate = async (config, services = []) => {
  const args = [...composeWithUpdateOverrideArgs(config), 'up', '-d', ...services];
  return run({ command: 'docker', args, cwd: config.composeProjectPath });
};

export const writeUpdateOverrideFile = async (config, images) => {
  const lines = [
    'services:',
    '  backend:',
    `    image: ${images.backend}`,
    '  frontend:',
    `    image: ${images.frontend}`,
    '',
  ];
  await fs.writeFile(config.updateOverrideFilePath, lines.join('\n'), 'utf8');
};

export const removeUpdateOverrideFile = async (config) => {
  await fs.rm(config.updateOverrideFilePath, { force: true });
};

export const writeRollbackOverrideFile = async (config, images) => {
  const lines = [
    'services:',
    '  backend:',
    `    image: ${images.backend}`,
    '  frontend:',
    `    image: ${images.frontend}`,
    '',
  ];

  await fs.writeFile(config.overrideComposeFilePath, lines.join('\n'), 'utf8');
};

export const removeRollbackOverrideFile = async (config) => {
  await fs.rm(config.overrideComposeFilePath, { force: true });
};

export const dockerLogin = async (config) => {
  const username = config.dockerAuth?.username;
  const token = config.dockerAuth?.token;
  const registry = config.dockerAuth?.registry; // optional for Docker Hub

  if (!username || !token) return { skipped: true };

  const args = ['login', '-u', username, '-p', token];
  if (registry) args.push(registry);

  // redact token index in error outputs
  const redactArgsIndices = [4];
  return run({ command: 'docker', args, cwd: config.composeProjectPath, redactArgsIndices });
};
