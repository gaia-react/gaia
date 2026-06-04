/**
 * Zod schema + read/write helpers for the revert-attempt ledger.
 *
 * Mirrors the `automation-state` module: discriminated `read*` result,
 * never throws, atomic writer using tmp-file + rename.
 *
 * The ledger file lives at `.gaia/automation.state-revert-attempts.json`.
 * It is **the** source of truth for the SPEC's hard cap of one revert
 * attempt per original PR (UAT-010). The CLI's `ci-revert open` handler
 * consults `attempts[<original_pr>]` before doing any git/`gh` work and
 * refuses to re-open if an entry already exists.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {z} from 'zod';
import {revertLedgerPath} from '../ci/paths.js';
import {summarizeZodError} from './zod-error.js';

export const RevertAttemptStatusSchema = z.literal([
  'failed',
  'merged',
  'open',
] as const);
export type RevertAttemptStatus = z.infer<typeof RevertAttemptStatusSchema>;

export const RevertAttemptSchema = z.object({
  opened_at: z.iso.datetime(),
  original_pr: z.number().int().positive(),
  revert_pr: z.number().int().positive(),
  status: RevertAttemptStatusSchema,
});
export type RevertAttempt = z.infer<typeof RevertAttemptSchema>;

export const RevertLedgerSchema = z.object({
  attempts: z.record(z.string(), RevertAttemptSchema),
  version: z.literal(1),
});
export type RevertLedger = z.infer<typeof RevertLedgerSchema>;

export const emptyRevertLedger = (): RevertLedger => ({
  attempts: {},
  version: 1,
});

export type ReadRevertLedgerResult =
  | {ledger: RevertLedger; status: 'ok'}
  | {status: 'missing'}
  | {error: string; status: 'malformed'};

export const readRevertLedger = (repoRoot: string): ReadRevertLedgerResult => {
  const filePath = revertLedgerPath(repoRoot);

  if (!existsSync(filePath)) return {status: 'missing'};

  let raw: string;

  try {
    raw = readFileSync(filePath, 'utf8');
  } catch (error) {
    return {
      error: `${filePath}: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return {
      error: `${filePath}: invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = RevertLedgerSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {ledger: result.data, status: 'ok'};
};

export const writeRevertLedger = (
  repoRoot: string,
  ledger: RevertLedger
): void => {
  const target = revertLedgerPath(repoRoot);
  mkdirSync(path.dirname(target), {recursive: true});

  const serialized = `${JSON.stringify(ledger, null, 2)}\n`;
  const tmpPath = `${target}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, target);
};

/** A revert-open run does ~6 git/gh calls; a lock older than this is
 *  presumed orphaned by a killed process and is reclaimed. */
const STALE_LOCK_MS = 5 * 60_000;

/**
 * Acquire an advisory lock around a ledger read-modify-write for one PR.
 *
 * The "one revert per PR" hard cap is a check-then-act on a shared file:
 * `ci-revert open` reads the ledger, confirms no entry exists, then does
 * several slow `git`/`gh` calls before writing the entry back. Two
 * concurrent invocations targeting the same PR can both pass the check and
 * both open a revert PR. `mkdir` is atomic on POSIX, so it serves as the
 * lock primitive; exactly one caller wins the directory create.
 *
 * The lock is scoped per `originalPr`: the lock directory carries the PR
 * number, so reverts of distinct PRs touch disjoint locks and never
 * serialize against each other.
 *
 * A process killed between `mkdir` and the `finally` release leaves the
 * lock directory orphaned. To recover, an existing lock older than
 * `STALE_LOCK_MS` (by mtime) is treated as stale and reclaimed.
 *
 * Returns `{locked: true}` and runs `critical` under the lock, or returns
 * `{locked: false}` without running it when a fresh lock for the same PR
 * is already held (a concurrent revert is in flight; refuse rather than
 * race). A non-`EEXIST` failure from lock acquisition propagates to the
 * caller as a genuine error rather than being masked as contention.
 */
export const withRevertLedgerLock = <T>(
  repoRoot: string,
  originalPr: number,
  critical: () => T
): {locked: false} | {locked: true; value: T} => {
  const target = revertLedgerPath(repoRoot);
  mkdirSync(path.dirname(target), {recursive: true});
  // `originalPr` is a positive integer (RevertAttemptSchema.original_pr),
  // so it is filename-safe with no sanitization.
  const lockDir = `${target}.lock.pr-${originalPr}`;

  try {
    // `recursive: false` is the default; fails with EEXIST if the lock
    // directory already exists, which is the contended path.
    mkdirSync(lockDir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;

    // EEXIST: a lock already exists. Reclaim it only if it is stale.
    if (!reclaimStaleLock(lockDir)) return {locked: false};
  }

  try {
    return {locked: true, value: critical()};
  } finally {
    rmSync(lockDir, {force: true, recursive: true});
  }
};

/**
 * Attempt to take over a pre-existing lock directory after an `EEXIST`.
 *
 * Returns `true` when this caller now holds the lock (the prior lock was
 * stale and has been reclaimed, or it vanished and was re-created), and
 * `false` when a fresh lock is still held by a live concurrent revert.
 */
const reclaimStaleLock = (lockDir: string): boolean => {
  let mtimeMs: number;

  try {
    mtimeMs = statSync(lockDir).mtimeMs;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;

    // The lock vanished between the failed `mkdir` and the `stat`; retry.
    return retryLockMkdir(lockDir);
  }

  // A fresh lock belongs to a healthy concurrent revert; refuse.
  if (Date.now() - mtimeMs <= STALE_LOCK_MS) return false;

  // Stale: presumed orphaned by a killed process. Reclaim it.
  rmSync(lockDir, {force: true, recursive: true});

  return retryLockMkdir(lockDir);
};

/**
 * Re-create the lock directory once. Returns `false` when another process
 * won the race and re-created the lock first (`EEXIST`).
 */
const retryLockMkdir = (lockDir: string): boolean => {
  try {
    mkdirSync(lockDir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;

    return false;
  }

  return true;
};
