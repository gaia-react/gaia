/**
 * Anonymous one-time ping fired from `gaia init finalize`. No PII: the
 * payload is just an event name, the installed GAIA version, and the OS
 * platform. Must never throw or block; a network failure, timeout, or
 * unreadable manifest is swallowed so init's exit code is unaffected.
 *
 * `GAIA_TELEMETRY_PING_DISABLE=1` is an internal test/CI seam (not a
 * documented user-facing opt-out) so automated runs of `gaia init
 * finalize` don't generate real network traffic.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';

const PING_URL = 'https://telemetry.gaiareact.com/ping';
const TIMEOUT_MS = 2000;
const MANIFEST_RELATIVE = '.gaia/manifest.json';

const readGaiaVersion = (cwd: string): string => {
  try {
    const raw = readFileSync(path.join(cwd, MANIFEST_RELATIVE), 'utf8');
    const parsed = JSON.parse(raw) as {version?: unknown};

    return typeof parsed.version === 'string' ? parsed.version : 'unknown';
  } catch {
    return 'unknown';
  }
};

export const sendTelemetryPing = async (cwd: string): Promise<void> => {
  if (process.env.GAIA_TELEMETRY_PING_DISABLE === '1') return;

  try {
    await fetch(PING_URL, {
      body: JSON.stringify({
        event: 'init',
        gaiaVersion: readGaiaVersion(cwd),
        platform: process.platform,
      }),
      headers: {'content-type': 'application/json'},
      method: 'POST',
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch {
    // Anonymous best-effort ping; never surface a failure.
  }
};
