import {existsSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {resolveMainWorktreeRoot} from '../../util/main-root.js';

const CACHE_RELATIVE_PATH = path.join(
  '.gaia',
  'local',
  'cache',
  'shared',
  'update-check.json'
);

/**
 * Mark the statusline refresher cache stale (`checkedAt: 0`) so the next render
 * recomputes `wikiDriftCount` from the post-land `wiki/.state.json`. Zeroing the
 * cached count instead would come back on the next refresher run. No-op when the
 * file is absent or not a JSON object; never throws.
 */
export const invalidateStatuslineCache = (repoRoot: string): void => {
  try {
    const cachePath = path.join(
      resolveMainWorktreeRoot(repoRoot),
      CACHE_RELATIVE_PATH
    );

    if (!existsSync(cachePath)) return;

    const parsed: unknown = JSON.parse(readFileSync(cachePath, 'utf8'));

    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed))
      return;

    // Temp file beside the target so the rename stays on one filesystem.
    const temporaryPath = `${cachePath}.${process.pid}.tmp`;

    writeFileSync(
      temporaryPath,
      `${JSON.stringify({...parsed, checkedAt: 0}, null, 2)}\n`,
      'utf8'
    );
    renameSync(temporaryPath, cachePath);
  } catch {
    // Best-effort: a stale nudge is recoverable, a failed land is not.
  }
};
