/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking the permission bits. */
import {existsSync, readFileSync} from 'node:fs';
import {appendFile, chmod, stat} from 'node:fs/promises';

type AppendArgs = {
  eventId: string;
  fileMode: 0o600 | 0o644;
  filePath: string;
  line: string;
};

type AppendResult = {
  written: boolean;
};

/**
 * Process-lifetime cache of `event_id`s known to already be present in a
 * given NDJSON file. Keyed by `filePath`. Seeded lazily by a single full
 * read the first time a file is touched this process; every emit after
 * that dedupes purely against the in-memory set.
 *
 * This bounds disk reads to one per file per process instead of one per
 * emit — the prior implementation re-read the whole daily file on every
 * call, which is O(n^2) over a day of emits from a long-lived process.
 */
const seenByFile = new Map<string, Set<string>>();

const EVENT_ID_NEEDLE_REGEX = /"event_id":"([^"]+)"/gu;

/**
 * Lazily build (and cache) the seen-set for `filePath` by scanning the
 * file once. A missing file yields an empty set.
 */
const seenSetFor = (filePath: string): Set<string> => {
  const cached = seenByFile.get(filePath);

  if (cached !== undefined) return cached;

  const seen = new Set<string>();

  if (existsSync(filePath)) {
    const existing = readFileSync(filePath, 'utf8');

    for (const match of existing.matchAll(EVENT_ID_NEEDLE_REGEX)) {
      seen.add(match[1] as string);
    }
  }

  seenByFile.set(filePath, seen);

  return seen;
};

/**
 * Append a JSON line to the NDJSON file at `filePath`, but only if no line
 * with the same `event_id` already exists. Dedup runs against a
 * process-lifetime in-memory seen-set, seeded by a single file read the
 * first time the file is touched (catches duplicates from prior processes)
 * and updated on every successful append.
 *
 * Concurrent emits of the same content yield the same `event_id`, so the
 * dedup step may race across processes (both seed before either writes).
 * Acceptable for v1 — the worst case is a duplicate line per content
 * within the race window, against the desired single line. Daily rotation
 * keeps the dup window finite. v1.1 may add `flock` if real-world rates
 * demand it.
 *
 * Idempotency contract: same content twice -> exactly one event per stream.
 *
 * @returns `{ written: true }` on append; `{ written: false }` on duplicate.
 */
export const appendIdempotent = async (
  args: AppendArgs
): Promise<AppendResult> => {
  const {eventId, fileMode, filePath, line} = args;
  const seen = seenSetFor(filePath);

  if (seen.has(eventId)) {
    return {written: false};
  }

  await appendFile(filePath, `${line}\n`, {mode: fileMode});
  seen.add(eventId);

  // `appendFile`'s `mode` option only takes effect when creating the file.
  // Re-chmod to ensure the post-condition holds even when the file pre-existed
  // with looser permissions.
  try {
    const stats = await stat(filePath);
    const currentMode = stats.mode & 0o777;

    if (currentMode !== fileMode) {
      await chmod(filePath, fileMode);
    }
  } catch {
    // Mode check is best-effort; fall through and let the write stand.
  }

  return {written: true};
};
