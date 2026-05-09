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
import {existsSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {z} from 'zod';
import {revertLedgerPath} from '../ci/paths.js';

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

const summarizeZodError = (filePath: string, error: z.ZodError): string => {
  const lines = error.issues.map((issue) => {
    const pathStr = issue.path.length === 0 ? '<root>' : issue.path.join('.');

    return `${pathStr}: ${issue.message}`;
  });

  return `${filePath}: ${lines.join('; ')}`;
};

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
