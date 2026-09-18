/**
 * Zod schema + read/write helpers for the machine-local decline ledger.
 *
 * When an engineer declines a hardening candidate, that decline is recorded
 * only on their machine so it never vetoes the rule for a teammate. The
 * ledger holds one bounded entry per `finding_class`; re-recording a class
 * overwrites its timestamp, PR count, and denominator.
 *
 * The schema is version 2. An entry carries two optional fields,
 * `declined_at_audited_pr_count` and `tally_schema_version`: an entry
 * missing either one is legacy (recorded before the share-based re-surface
 * rule, or read from a version-1 file) and never suppresses, because a raw
 * count with no denominator cannot be compared to a live share honestly.
 * `readDeclineLedger` still accepts a version-1 file unconditionally; every
 * write (`record`, a `prune` that removes) emits `version: 2` and carries
 * any legacy entries forward unchanged.
 *
 * The file lives at `.gaia/local/harden/declines.json` (gitignored). A
 * corrupt or hand-edited file fails loud (the discriminated `read*` result
 * carries `status: 'malformed'`) rather than being silently treated as
 * empty, which would wrongly re-surface or wrongly suppress a candidate.
 * The path is shared across the clone's worktrees by the state registry's
 * symlink, so a decline recorded from a linked worktree lands in the main
 * checkout's copy and survives that worktree's removal.
 */
import {z} from 'zod';
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {summarizeZodError} from './zod-error.js';

export const declineLedgerPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'harden', 'declines.json');

export const DeclineEntrySchema = z.object({
  declined_at: z.iso.datetime(),
  declined_at_audited_pr_count: z.number().int().nonnegative().optional(),
  declined_at_pr_count: z.number().int().nonnegative(),
  finding_class: z.string().min(1),
  tally_schema_version: z.number().int().nonnegative().optional(),
});

export type DeclineEntry = z.infer<typeof DeclineEntrySchema>;

// `version` is declared first so JSON serialization emits it first, matching
// the frozen ledger shape (`{"version":2,"declines":[]}`).
export const DeclineLedgerSchema = z.object({
  version: z.union([z.literal(1), z.literal(2)]),
  // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
  declines: z.array(DeclineEntrySchema),
});

export type DeclineLedger = z.infer<typeof DeclineLedgerSchema>;

export const emptyDeclineLedger = (): DeclineLedger => ({
  version: 2,
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
  // Mode 755 matches the other `.gaia/local` state writers (setup-state, the
  // sandbox marker, project-id), so the directory stays traversable by a
  // subprocess running as another user.
  mkdirSync(path.dirname(target), {mode: 0o755, recursive: true});

  // Every write emits version 2 regardless of the version read, so a
  // version-1 file upgrades on its first touch while legacy entries carry
  // forward unchanged.
  const serialized = `${JSON.stringify({...ledger, version: 2}, null, 2)}\n`;
  atomicWriteFileSync(target, serialized);
};
