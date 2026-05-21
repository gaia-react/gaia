/**
 * Atomic file writes: serialize to a uniquely-named temporary file in the
 * target's own directory, fsync it so the bytes are durable, then rename
 * over the target. POSIX `rename` is atomic on the same filesystem; the
 * fsync is what makes the result crash-safe — without it a crash right
 * after the rename can leave the target pointing at unflushed (empty or
 * partial) data.
 */
import {
  closeSync,
  fsyncSync,
  openSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import {open, rename} from 'node:fs/promises';

// PID + monotonic high-res clock keeps concurrent writers — same process
// or different processes — from colliding on the temp file name.
const temporaryPath = (filePath: string): string =>
  `${filePath}.tmp.${process.pid}.${process.hrtime.bigint().toString()}`;

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

  renameSync(tmp, filePath);
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

  await rename(tmp, filePath);
};
