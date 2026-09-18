/**
 * Zod schema + read/write helpers for the machine-local review snapshot.
 *
 * A completed `/gaia-harden` review records what it reviewed so the
 * `/gaia-harden` statusline nudge can stay silent until something changes.
 * The review skill saves its start-of-run `harden-tally` JSON, then at each
 * completion point runs `harden-ledger snapshot record` against that saved
 * tally; the resulting snapshot is what trigger evaluation compares the live
 * tally against.
 *
 * The file lives at `.gaia/local/harden/reviewed.json` (gitignored). A
 * corrupt or hand-edited file fails loud (the discriminated `read*` result
 * carries `status: 'malformed'`) rather than being silently treated as
 * absent, which would wrongly re-fire the nudge on a reading nobody made.
 */
import {z} from 'zod';
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {summarizeZodError} from './zod-error.js';

export const reviewSnapshotPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'harden', 'reviewed.json');

const ClassSummarySchema = z.object({
  distinct_pr_count: z.number().int().min(1),
  share: z.number().min(0).max(1),
});

// `version` is declared first so JSON serialization emits it first, matching
// the ledger schemas' frozen shape convention.
export const ReviewSnapshotSchema = z.object({
  version: z.literal(1),
  // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
  audited_pr_count: z.number().int().nonnegative(),
  classes: z.record(z.string().min(1), ClassSummarySchema),
  reviewed_at: z.iso.datetime(),
  tally_schema_version: z.number().int().nonnegative(),
  unclassified: ClassSummarySchema.nullable(),
  window_days: z.number().int().positive(),
});

export type ReadReviewSnapshotResult =
  | {error: string; status: 'malformed'}
  | {snapshot: ReviewSnapshot; status: 'ok'}
  | {status: 'missing'};

export type ReviewSnapshot = z.infer<typeof ReviewSnapshotSchema>;

export const readReviewSnapshot = (
  repoRoot: string
): ReadReviewSnapshotResult => {
  const filePath = reviewSnapshotPath(repoRoot);

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

  const result = ReviewSnapshotSchema.safeParse(parsed);

  if (!result.success) {
    return {
      error: summarizeZodError(filePath, result.error),
      status: 'malformed',
    };
  }

  return {snapshot: result.data, status: 'ok'};
};

export const writeReviewSnapshot = (
  repoRoot: string,
  snapshot: ReviewSnapshot
): void => {
  const target = reviewSnapshotPath(repoRoot);
  // Mode 755 matches the other `.gaia/local` state writers (setup-state, the
  // sandbox marker, project-id, the decline ledger), so the directory stays
  // traversable by a subprocess running as another user.
  mkdirSync(path.dirname(target), {mode: 0o755, recursive: true});

  const serialized = `${JSON.stringify(snapshot, null, 2)}\n`;
  atomicWriteFileSync(target, serialized);
};

// The subset of the emitted `harden-tally` JSON a snapshot is built from.
// Loose: the real tally carries many more keys, and this schema only cares
// about the ones `snapshotFromTally` reads.
export const ReviewTallyInputSchema = z.looseObject({
  audited_pr_count: z.number().int().nonnegative(),
  class_inventory: z.array(
    z.object({
      distinct_pr_count: z.number().int().min(1),
      finding_class: z.string().min(1),
    })
  ),
  gh_ok: z.boolean(),
  tally_schema_version: z.number().int().nonnegative(),
  unclassified_window_count: z.number().int().min(1).nullable(),
  window_days: z.number().int().positive(),
});

export type ReviewTallyInput = z.infer<typeof ReviewTallyInputSchema>;

export const snapshotFromTally = (
  tally: ReviewTallyInput,
  now: Date
): ReviewSnapshot => {
  const share = (count: number): number =>
    tally.audited_pr_count > 0 ? count / tally.audited_pr_count : 0;

  const classes: ReviewSnapshot['classes'] = {};

  for (const entry of tally.class_inventory) {
    classes[entry.finding_class] = {
      distinct_pr_count: entry.distinct_pr_count,
      share: share(entry.distinct_pr_count),
    };
  }

  return {
    version: 1,
    // eslint-disable-next-line perfectionist/sort-objects -- serialization order load-bearing, version-first
    audited_pr_count: tally.audited_pr_count,
    classes,
    reviewed_at: now.toISOString(),
    tally_schema_version: tally.tally_schema_version,
    unclassified:
      tally.unclassified_window_count === null ?
        null
      : {
          distinct_pr_count: tally.unclassified_window_count,
          share: share(tally.unclassified_window_count),
        },
    window_days: tally.window_days,
  };
};
