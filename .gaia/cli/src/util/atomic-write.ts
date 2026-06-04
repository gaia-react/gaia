/**
 * Atomic file writes: serialize to a uniquely-named temporary file in the
 * target's own directory, fsync it so the bytes are durable, then rename
 * over the target. POSIX `rename` is atomic on the same filesystem; the
 * fsync is what makes the result crash-safe; without it a crash right
 * after the rename can leave the target pointing at unflushed (empty or
 * partial) data.
 */
import {randomBytes} from 'node:crypto';
import {
  closeSync,
  fsyncSync,
  openSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import {open, rename, unlink} from 'node:fs/promises';

// A crypto-random suffix keeps concurrent writers, same process or
// different processes, from colliding on the temp file name, and is
// portable across platforms.
const temporaryPath = (filePath: string): string =>
  `${filePath}.tmp.${randomBytes(8).toString('hex')}`;

export const atomicWriteFileSync = (
  filePath: string,
  data: Buffer | string,
  options?: {mode?: number}
): void => {
  const tmp = temporaryPath(filePath);
  const fd = openSync(tmp, 'w', options?.mode ?? 0o644);

  try {
    writeFileSync(fd, data);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }

  try {
    renameSync(tmp, filePath);
  } catch (error) {
    // Rename failed (cross-device, permissions, target dir removed): drop the
    // temp file so failed writes don't accumulate beside the target.
    try {
      unlinkSync(tmp);
    } catch {
      // best-effort cleanup
    }

    throw error;
  }
};

export const atomicWriteFile = async (
  filePath: string,
  data: Buffer | string,
  options?: {mode?: number}
): Promise<void> => {
  const tmp = temporaryPath(filePath);
  const handle = await open(tmp, 'w', options?.mode ?? 0o644);

  try {
    await handle.writeFile(data);
    await handle.sync();
  } finally {
    await handle.close();
  }

  try {
    await rename(tmp, filePath);
  } catch (error) {
    // Rename failed (cross-device, permissions, target dir removed): drop the
    // temp file so failed writes don't accumulate beside the target.
    try {
      await unlink(tmp);
    } catch {
      // best-effort cleanup
    }

    throw error;
  }
};
