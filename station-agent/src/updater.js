import fs from 'node:fs/promises';
import {
  dockerComposePull,
  dockerComposePullRollback,
  dockerComposePullUpdate,
  dockerComposeUp,
  dockerComposeUpRollback,
  dockerComposeUpUpdate,
  getCurrentImages,
  removeRollbackOverrideFile,
  removeUpdateOverrideFile,
  dockerLogin,
  writeRollbackOverrideFile,
  writeUpdateOverrideFile,
} from './docker.js';
import { runHealthcheck } from './healthcheck.js';
import { isVersionEqual, isVersionGreater } from './version.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const nowIso = () => new Date().toISOString();

export class StationUpdater {
  constructor(config) {
    this.config = config;
    this.currentVersion = config.currentVersionDefault;
    this.latestVersion = config.currentVersionDefault;
    this.latestImages = null;
    this.updateAvailable = false;
    this.updating = false;
    this.lastError = null;
    this.lastCheckAt = null;
    this.intervalId = null;
  }

  log(event, details = {}) {
    const payload = {
      time: nowIso(),
      event,
      ...details,
    };
    console.log(JSON.stringify(payload));
  }

  async init() {
    await fs.mkdir(this.config.dataDir, { recursive: true });
    await this.loadCurrentVersion();
  }

  async loadCurrentVersion() {
    try {
      const content = await fs.readFile(this.config.currentVersionFilePath, 'utf8');
      const fromFile = content.trim();
      if (fromFile) {
        this.currentVersion = fromFile;
      }
    } catch {
      await this.persistCurrentVersion(this.currentVersion);
    }
  }

  async persistCurrentVersion(version) {
    this.currentVersion = version;
    await fs.writeFile(this.config.currentVersionFilePath, `${version}\n`, 'utf8');
  }

  getStatus() {
    return {
      currentVersion: this.currentVersion,
      latestVersion: this.latestVersion,
      updateAvailable: this.updateAvailable,
      updating: this.updating,
      lastCheckAt: this.lastCheckAt,
      lastError: this.lastError,
    };
  }

  startPeriodicChecks() {
    const intervalMs = this.config.checkIntervalMinutes * 60 * 1000;

    this.checkForUpdates().catch((error) => {
      this.lastError = error instanceof Error ? error.message : String(error);
    });

    this.intervalId = setInterval(() => {
      this.checkForUpdates().catch((error) => {
        this.lastError = error instanceof Error ? error.message : String(error);
      });
    }, intervalMs);
  }

  stopPeriodicChecks() {
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  async checkForUpdates() {
    // Since UPDATE_SERVER_URL may now point directly to a static release manifest
    // like https://.../release.json, we use it as-is without appending paths.
    const url = this.config.updateServerUrl;
    const response = await fetch(url, { method: 'GET' });

    if (!response.ok) {
      throw new Error(`Update server request failed with status ${response.status}`);
    }

    const payload = await response.json();
    this.lastCheckAt = nowIso();
    this.latestVersion = payload.version ?? this.currentVersion;
    this.latestImages = payload.images ?? null;
    this.updateAvailable = isVersionGreater(this.latestVersion, this.currentVersion);

    if (this.updateAvailable) {
      this.log('update_available', {
        currentVersion: this.currentVersion,
        latestVersion: this.latestVersion,
      });

      if (this.config.autoUpdate) {
        await this.update({ version: this.latestVersion });
      }
    }

    return payload;
  }

  async createRollbackSnapshot() {
    const images = await getCurrentImages(this.config);
    const snapshot = {
      version: this.currentVersion,
      images,
    };

    await fs.writeFile(this.config.rollbackFilePath, JSON.stringify(snapshot, null, 2), 'utf8');
    return snapshot;
  }

  ensureLock() {
    if (this.updating) {
      const error = new Error('Update already in progress');
      error.statusCode = 409;
      throw error;
    }

    this.updating = true;
  }

  releaseLock() {
    this.updating = false;
  }

  async update({ version, images: providedImages } = {}) {
    this.ensureLock();
    this.lastError = null;
    let snapshotCreated = false;

    const images = providedImages ?? this.latestImages ?? null;

    try {
      this.log('update_start', {
        requestedVersion: version ?? null,
        currentVersion: this.currentVersion,
        images: images ?? 'latest',
      });

      await this.createRollbackSnapshot();
      snapshotCreated = true;

      this.log('docker_pull', { services: this.config.services });
      // Try to login if creds provided
      try {
        await dockerLogin(this.config);
      } catch {
        // ignore login errors here; pull may still succeed for public images
      }
      await removeRollbackOverrideFile(this.config);

      if (images) {
        await writeUpdateOverrideFile(this.config, images);
      } else {
        await removeUpdateOverrideFile(this.config);
      }

      const pull = images
        ? () => dockerComposePullUpdate(this.config, this.config.services)
        : () => dockerComposePull(this.config, this.config.services);

      try {
        await pull();
      } catch {
        // On pull error, attempt one more login and retry once
        try {
          await dockerLogin(this.config);
          await pull();
        } catch (err2) {
          throw err2;
        }
      }

      this.log('docker_restart', { services: this.config.services });
      if (images) {
        await dockerComposeUpUpdate(this.config, this.config.services);
      } else {
        await dockerComposeUp(this.config, this.config.services);
      }

      await sleep(this.config.stabilizationSeconds * 1000);

      const health = await runHealthcheck(this.config.healthcheckUrl, this.config.requestTimeoutMs);
      if (!health.ok) {
        this.log('healthcheck_failed', health);
        throw new Error(
          `Healthcheck failed after update. status=${health.status} error=${health.error}`,
        );
      }

      this.log('healthcheck_passed', { status: health.status });

      await removeUpdateOverrideFile(this.config);

      const targetVersion =
        version && !isVersionEqual(version, this.currentVersion)
          ? version
          : this.latestVersion || this.currentVersion;

      await this.persistCurrentVersion(targetVersion);
      this.updateAvailable = isVersionGreater(this.latestVersion, this.currentVersion);

      this.log('update_completed', { currentVersion: this.currentVersion });
      return this.getStatus();
    } catch (error) {
      if (snapshotCreated) {
        try {
          await this.rollbackInternal();
        } catch (rollbackError) {
          this.lastError = `Update failed: ${error instanceof Error ? error.message : String(error)} | Rollback failed: ${rollbackError instanceof Error ? rollbackError.message : String(rollbackError)}`;
          throw rollbackError;
        }
      }

      this.lastError = error instanceof Error ? error.message : String(error);
      throw error;
    } finally {
      this.releaseLock();
    }
  }

  async rollback() {
    this.ensureLock();

    try {
      const result = await this.rollbackInternal();
      return result;
    } finally {
      this.releaseLock();
    }
  }

  async rollbackInternal() {
    this.log('rollback_started');

    const raw = await fs.readFile(this.config.rollbackFilePath, 'utf8');
    const snapshot = JSON.parse(raw);

    if (!snapshot?.images?.backend || !snapshot?.images?.frontend) {
      throw new Error('Invalid rollback snapshot: images are missing');
    }

    await writeRollbackOverrideFile(this.config, snapshot.images);

    this.log('docker_pull', {
      mode: 'rollback',
      services: this.config.services,
    });
    try {
      await dockerLogin(this.config);
    } catch {
      // ignore
    }
    try {
      await dockerComposePullRollback(this.config, this.config.services);
    } catch (err) {
      try {
        await dockerLogin(this.config);
        await dockerComposePullRollback(this.config, this.config.services);
      } catch (err2) {
        throw err2;
      }
    }

    this.log('docker_restart', {
      mode: 'rollback',
      services: this.config.services,
    });
    await dockerComposeUpRollback(this.config, this.config.services);

    await sleep(this.config.stabilizationSeconds * 1000);

    const health = await runHealthcheck(this.config.healthcheckUrl, this.config.requestTimeoutMs);
    if (!health.ok) {
      this.log('healthcheck_failed', { mode: 'rollback', ...health });
      throw new Error(
        `Healthcheck failed after rollback. status=${health.status} error=${health.error}`,
      );
    }

    this.log('healthcheck_passed', { mode: 'rollback', status: health.status });

    await this.persistCurrentVersion(snapshot.version);
    this.updateAvailable = isVersionGreater(this.latestVersion, this.currentVersion);

    this.log('rollback_completed', { currentVersion: this.currentVersion });
    return this.getStatus();
  }
}
