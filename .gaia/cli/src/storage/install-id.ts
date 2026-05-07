import {ulid} from 'ulid';
import {chmodSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
import type {StorageRoots} from './paths.js';

/**
 * Read or generate the install-id at <home>/.claude/projects/<slug>/gaia/install-id.txt.
 * Returns the ULID. Side effect: writes the file with mode 600 if absent.
 *
 * Caller must ensureMentorshipDirs first — this function does not create parent
 * directories. Synchronous so it can be called from emit-time hot paths without
 * forcing them async.
 */
export const readOrCreateInstallId = (roots: StorageRoots): string => {
  const filePath = roots.installIdPath;

  if (existsSync(filePath)) {
    const existing = readFileSync(filePath, 'utf8').trim();

    if (existing.length === 26) {
      return existing;
    }
    // Malformed (truncated, empty, or wrong length) — regenerate.
  }
  const id = ulid();
  writeFileSync(filePath, `${id}\n`, {mode: 0o600});
  // writeFileSync's mode option is honored only on file creation; explicit
  // chmod handles the regenerate-over-malformed case.
  chmodSync(filePath, 0o600);

  return id;
};
