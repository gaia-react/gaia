import {z} from 'zod';
/**
 * Zod schema + read/write helpers for the machine-local decline ledger.
 *
 * When an engineer declines a hardening candidate, that decline is recorded
 * only on their machine so it never vetoes the rule for a teammate. The
 * ledger holds one bounded entry per `finding_class`; re-recording a class
 * overwrites its timestamp and PR count.
 *
 * The file lives at `.gaia/local/harden/declines.json` (gitignored). A
 * corrupt or hand-edited file fails loud (the discriminated `read*` result
 * carries `status: 'malformed'`) rather than being silently treated as
 * empty, which would wrongly re-surface or wrongly suppress a candidate.
 */
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {summarizeZodError} from './zod-error.js';

export const declineLedgerPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'harden', 'declines.json');

export const DeclineEntrySchema = z.object({
  declined_at: z.iso.datetime(),
  declined_at_pr_count: z.number().int().nonnegative(),
  finding_class: z.string().min(1),
});

export type DeclineEntry = z.infer<typeof DeclineEntrySchema>;

// `version` is declared first so JSON serialization emits it first, matching
// the frozen ledger shape (`{"version":1,"declines":[]}`).
export const DeclineLedgerSchema = z.object({
  version: z.literal(1),
  // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
  declines: z.array(DeclineEntrySchema),
});

export type DeclineLedger = z.infer<typeof DeclineLedgerSchema>;

export const emptyDeclineLedger = (): DeclineLedger => ({
  version: 1,
  // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
  declines: [],
});

export type ReadDeclineLedgerResult =
  | {error: string; status: 'malformed'}
  | {ledger: DeclineLedger; status: 'ok'}
  | {status: 'missing'};

export const readDeclineLedger = (
  repoRoot: string
): ReadDeclineLedgerResult => {
  const filePath = declineLedgerPath(repoRoot);

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

  const result = DeclineLedgerSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {ledger: result.data, status: 'ok'};
};

export const writeDeclineLedger = (
  repoRoot: string,
  ledger: DeclineLedger
): void => {
  const target = declineLedgerPath(repoRoot);
  // Mode 755 matches the in-project dir convention (`ensureInProjectDirectory`
  // in storage/paths.ts).
  mkdirSync(path.dirname(target), {mode: 0o755, recursive: true});

  const serialized = `${JSON.stringify(ledger, null, 2)}\n`;
  atomicWriteFileSync(target, serialized);
};
