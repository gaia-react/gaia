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
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {z} from 'zod';
import {revertLedgerPath} from '../ci/paths.js';
import {summarizeZodError} from './zod-error.js';

export const RevertAttemptStatusSchema = z.literal(['failed', 'merged', 'open'] as const);
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
      error: `${filePath}: invalid JSON — ${error instanceof Error ? error.message : String(error)}`,
      status: 'malformed',
    };
  }

  const result = RevertLedgerSchema.safeParse(parsed);

  if (!result.success) {
    return {error: summarizeZodError(filePath, result.error), status: 'malformed'};
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

/**
 * Acquire an advisory lock around a ledger read-modify-write.
 *
 * The "one revert per PR" hard cap is a check-then-act on a shared file:
 * `ci-revert open` reads the ledger, confirms no entry exists, then does
 * several slow `git`/`gh` calls before writing the entry back. Two
 * concurrent invocations can both pass the check and both open a revert
 * PR. `mkdir` is atomic on POSIX, so it serves as the lock primitive —
 * exactly one caller wins the directory create.
 *
 * Returns `true` and runs `critical` under the lock, or returns `false`
 * without running it when the lock is already held (a concurrent revert
 * is in flight — refuse rather than race).
 */
export const withRevertLedgerLock = <T>(
  repoRoot: string,
  critical: () => T
): {locked: false} | {locked: true; value: T} => {
  const target = revertLedgerPath(repoRoot);
  mkdirSync(path.dirname(target), {recursive: true});
  const lockDir = `${target}.lock`;

  try {
    // `recursive: false` is the default — fails with EEXIST if the lock
    // directory already exists, which is the contended path.
    mkdirSync(lockDir);
  } catch {
    return {locked: false};
  }

  try {
    return {locked: true, value: critical()};
  } finally {
    rmSync(lockDir, {force: true, recursive: true});
  }
};
