/**
 * Shared "gaia ping" core: a fire-and-forget POST to the adoption ping
 * at PING_URL, shared by the `init`, `setup`, and `update` events.
 * Pseudonymous-per-install, not anonymous: the body carries a stable
 * `projectId` (derived from the repo path, see `../storage/project-id.ts`)
 * so the server can correlate one install's init -> setup -> update
 * events, but it never carries user paths or free text beyond the
 * low-cardinality categorical fields each event defines.
 *
 * Must never throw or block; a network failure, timeout, unreadable
 * manifest, or project-id write failure is swallowed so the caller's exit
 * code is unaffected.
 *
 * `GAIA_TELEMETRY_PING_DISABLE=1` suppresses the ping (checked first): it is
 * documented in `gaia ping --help` and the Telemetry wiki page as the switch
 * that turns the ping off, and it doubles as the test/CI seam so automated
 * runs generate no real network traffic.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {readOrCreateProjectId, resolveStorageRoots} from '../storage/index.js';

export type PingEvent = 'init' | 'setup' | 'update';

export type PingPayload = Record<string, number | string> & {event: PingEvent};

const PING_URL = 'https://telemetry.gaiareact.com/ping';
const TIMEOUT_MS = 2000;
const MANIFEST_RELATIVE = '.gaia/manifest.json';

const PLATFORM_LABELS: Readonly<Record<string, string>> = {
  darwin: 'macos',
  linux: 'linux',
  win32: 'windows',
};

/**
 * Collapse `process.platform` to a coarse, low-cardinality label
 * (`macos` / `windows` / `linux`), folding the long tail (`freebsd`,
 * `android`, …) into `other`. Keeps the ping's `platform` field a clean
 * four-value enum rather than leaking Node's `darwin` / `win32` jargon.
 */
export const normalizePlatform = (platform: string): string =>
  PLATFORM_LABELS[platform] ?? 'other';

const readGaiaVersion = (cwd: string): string => {
  try {
    const raw = readFileSync(path.join(cwd, MANIFEST_RELATIVE), 'utf8');
    const parsed = JSON.parse(raw) as {version?: unknown};

    return typeof parsed.version === 'string' ? parsed.version : 'unknown';
  } catch {
    return 'unknown';
  }
};

const readProjectId = (cwd: string): string | undefined => {
  try {
    return readOrCreateProjectId(resolveStorageRoots({repoRoot: cwd}));
  } catch {
    return undefined;
  }
};

export const postPing = async (
  cwd: string,
  payload: PingPayload
): Promise<void> => {
  if (process.env.GAIA_TELEMETRY_PING_DISABLE === '1') return;

  const projectId = readProjectId(cwd);
  const body = {
    ...payload,
    ...(projectId ? {projectId} : {}),
    gaiaVersion: readGaiaVersion(cwd),
    platform: normalizePlatform(process.platform),
  };

  try {
    await fetch(PING_URL, {
      body: JSON.stringify(body),
      headers: {'content-type': 'application/json'},
      method: 'POST',
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch {
    // Best-effort ping; never surface a failure.
  }
};
