/**
 * `gaia harden-tally` - the deterministic, TTL-bounded recurrence tally for the
 * policy-memory loop.
 *
 * Resolves the rolling 90-day merged-PR window via `gh`, extracts each PR's
 * machine-readable findings block, counts distinct PRs per `finding_class` at
 * any severity, drops classes a promoted rule already covers or the decline
 * ledger suppresses, self-cleans the ledger, and prints the candidate list
 * plus the classless `unclassified` recurrence signal as JSON to stdout. The
 * statusline refresher composes a nudge reason from `triggers` (or from
 * counts when no review snapshot exists); `/gaia-harden review` re-runs this
 * to get the live list.
 *
 * No LLM, no drafting, no writes other than (indirectly) the ledger prune. The
 * window read is the only network access and it is non-fatal: a gh failure or
 * a window the paged read cannot finish yields an empty candidate list and
 * `gh_ok: false` rather than aborting the refresher.
 *
 * `audited_pr_count` and `class_inventory` give a review snapshot the full
 * denominator and vocabulary it needs; `triggers` names what changed against
 * the last completed review's snapshot (`.gaia/local/harden/reviewed.json`),
 * evaluated by `evaluateTriggers` (`triggers.ts`).
 */
import path from 'node:path';
import {
  MERGED_PR_PAGE_CEILING,
  MERGED_PR_WINDOW_MAX_PAGES,
  readMergedPrWindow,
} from '../ci/util/merged-pr-window.js';
import {EXIT_CODES} from '../exit.js';
import {readReviewSnapshot} from '../schemas/review-snapshot.js';
import {structuredError} from '../stderr.js';
import {computeTally, windowClasses} from './compute-tally.js';
import type {TallyPrRecord, TallyResult} from './compute-tally.js';
import {coveredClassesFromRules} from './covered-classes.js';
import {
  defaultLedgerRunner,
  makeLedgerSuppressionPredicate,
  pruneLedger,
} from './ledger-bridge.js';
import type {LedgerRunner} from './ledger-bridge.js';
import {TALLY_SCHEMA_VERSION} from './material-rise.js';
import {parseFindingsBlock} from './parse-findings-block.js';
import {evaluateTriggers} from './triggers.js';
import type {HardenTrigger} from './triggers.js';

const HELP_TEXT = `Usage: gaia harden-tally

  Tallies recurring code-review-audit findings across the rolling 90-day
  merged-PR window and prints the candidate list as JSON. A class is a
  candidate when it recurs across >= 3 distinct PRs at any severity, no
  promoted rule covers it, and the decline ledger does not suppress it. A
  classless (unclassified) finding recurring the same way surfaces separately
  as the \`unclassified\` field instead of a candidate.

  Also emits audited_pr_count (the window's audited-PR denominator),
  class_inventory (every counted class, below-threshold included),
  unclassified_window_count (the classless count below its signal
  threshold), tally_schema_version, and, against the last completed
  review's snapshot, snapshot_present / snapshot_reviewed_at / triggers.

  Network failures are non-fatal: gh errors yield an empty candidate list
  and gh_ok: false. A window the paged read cannot finish does the same,
  with a window_truncated error on stderr, since reading part of it as the
  whole would undercount every class.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export const WINDOW_DAYS = 90;

/** The emitted tally JSON: the pure result plus the window-read fields. */
type EmittedTally = TallyResult & {
  gh_ok: boolean;
  snapshot_present: boolean;
  snapshot_reviewed_at: null | string;
  tally_schema_version: number;
  triggers: HardenTrigger[];
};

type RunOptions = {
  cwd?: string;
  runLedger?: LedgerRunner;
};

/**
 * The window read plus a success flag. `ghOk` is `true` when the merged-PR
 * window was read successfully (including a genuinely empty window) and `false`
 * when the `gh` read failed, so a network outage is distinguishable from an
 * all-clear at the emit boundary.
 */
type WindowPrs = {
  ghOk: boolean;
  prs: TallyPrRecord[];
};

const windowStartDate = (now: Date): string => {
  const start = new Date(now.getTime() - WINDOW_DAYS * 24 * 60 * 60 * 1000);

  return start.toISOString().slice(0, 10);
};

type GhPr = {
  comments: {body: string}[];
  number: number;
};

const parseGhPr = (value: unknown): GhPr | null => {
  if (typeof value !== 'object' || value === null) return null;
  const v = value as Record<string, unknown>;

  if (typeof v.number !== 'number' || !Number.isFinite(v.number)) return null;
  if (!Array.isArray(v.comments)) return null;

  const comments: {body: string}[] = [];

  for (const comment of v.comments) {
    if (
      typeof comment === 'object' &&
      comment !== null &&
      typeof (comment as Record<string, unknown>).body === 'string'
    ) {
      comments.push({
        body: (comment as Record<string, unknown>).body as string,
      });
    }
  }

  return {comments, number: v.number};
};

// tally-semantics:start
// Builds a tally record from a parsed gh PR, merging findings PER AUDITOR: for
// each parseable block, the block's `auditor` field (normalized to `''` for a
// missing/empty/non-string auditor by the parser) keys a Map, so a later
// block from the SAME auditor supersedes its own earlier one (a re-run audit
// supersedes an earlier run), while blocks from DIFFERENT auditors on the
// same PR both survive. The merged record flattens every auditor's surviving
// findings in Map insertion order (gh's chronological comment order). A PR
// with at least one parseable block (even one with an empty findings array)
// is "audited": this is the predicate `audited_pr_count` counts. Returns null
// when no comment carries a parseable block.
const recordFromGhPr = (pr: GhPr): null | TallyPrRecord => {
  const byAuditor = new Map<string, TallyPrRecord['findings']>();

  for (const comment of pr.comments) {
    const block = parseFindingsBlock(comment.body);

    if (block !== null) byAuditor.set(block.auditor, block.findings);
  }

  if (byAuditor.size === 0) return null;

  return {findings: [...byAuditor.values()].flat(), pr_number: pr.number};
};
// tally-semantics:end

/**
 * Reads the merged-PR window via gh. Returns one record per PR that carries a
 * parseable findings block, merging every auditor's findings on that PR
 * (latest block wins per auditor; see `recordFromGhPr`), alongside `ghOk`.
 * `ghOk` is `false` on any read failure (non-zero exit, unparseable JSON, a
 * well-formed-but-non-array response) and on a window the paged read could not
 * finish, and `true` otherwise, including a genuinely empty window. The
 * refresher never blocks: an empty `prs` list is returned in every failure
 * case.
 */
const fetchWindowPrs = (cwd: string, now: Date): WindowPrs => {
  const window = readMergedPrWindow<{createdAt: string; number: number}>({
    cwd,
    fields: ['comments'],
    sinceIso: windowStartDate(now),
  });

  if (!window.ok) return {ghOk: false, prs: []};

  // An unfinished window is not a complete one: reading it as whole would
  // undercount every class and let the ledger prune declines the unread PRs
  // still carry. The stderr line is what separates this from an outage, whose
  // remedy (wait for gh) does not fix it.
  if (window.truncated) {
    structuredError({
      code: 'window_truncated',
      message: `the merged-PR window holds more than ${MERGED_PR_WINDOW_MAX_PAGES * MERGED_PR_PAGE_CEILING} PRs, more than the paged read covers; report this as a GAIA bug`,
      subcommand: 'harden-tally',
    });

    return {ghOk: false, prs: []};
  }

  const records: TallyPrRecord[] = [];

  for (const value of window.prs) {
    const pr = parseGhPr(value);
    const record = pr === null ? null : recordFromGhPr(pr);

    if (record !== null) records.push(record);
  }

  return {ghOk: true, prs: records};
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const cwd = options.cwd ?? process.cwd();
  const runLedger = options.runLedger ?? defaultLedgerRunner;
  const now = new Date();

  const {ghOk, prs} = fetchWindowPrs(cwd, now);
  const covered = coveredClassesFromRules(path.join(cwd, '.claude', 'rules'));

  const tallyResult = computeTally({
    coveredClass: (findingClass) => covered.has(findingClass),
    prs,
    suppressedClass: makeLedgerSuppressionPredicate({cwd, runLedger}),
    windowDays: WINDOW_DAYS,
  });

  // Self-clean the ledger: drop declines whose class no longer recurs. Gated on
  // `ghOk` because a failed window read also yields an empty `prs`, which the
  // prune would read as authoritative evidence that every declined class
  // stopped recurring and wipe the ledger. An unread window is not evidence, so
  // this fails closed, matching `makeLedgerSuppressionPredicate`.
  if (ghOk) pruneLedger({cwd, runLedger, windowClasses: windowClasses(prs)});

  // Read the review snapshot unconditionally (not gated on `ghOk`), so a
  // malformed snapshot is always reported. A malformed snapshot reads as
  // absent for trigger purposes: trusting a corrupt file's counts would risk
  // a wrong comparison, and a missing one already means "every candidate is
  // new" via the no-snapshot rule below.
  const snapshotResult = readReviewSnapshot(cwd);

  if (snapshotResult.status === 'malformed') {
    structuredError({
      code: 'malformed_snapshot',
      message: snapshotResult.error,
      subcommand: 'harden-tally',
    });
  }

  const snapshot =
    snapshotResult.status === 'ok' ? snapshotResult.snapshot : null;

  // Triggers only evaluate against a real snapshot read on a successful
  // window read: a failed `gh` read yields an empty, non-authoritative
  // `prs`/`candidates`, so comparing it to the snapshot would report a false
  // "everything vanished" rather than staying silent until the window reads
  // again.
  const triggers: HardenTrigger[] =
    ghOk && snapshot !== null ?
      evaluateTriggers({
        live: {
          auditedPrCount: tallyResult.audited_pr_count,
          candidates: tallyResult.candidates,
          tallySchemaVersion: TALLY_SCHEMA_VERSION,
          unclassified:
            tallyResult.unclassified === null ?
              null
            : {distinct_pr_count: tallyResult.unclassified.distinct_pr_count},
        },
        snapshot,
      })
    : [];

  // Emit `gh_ok` at the I/O boundary so a gh outage is distinguishable from an
  // all-clear. It stays off the pure `TallyResult`: the tally core cannot know
  // whether the window read succeeded. The read is non-fatal, so run() still
  // exits 0 in every case.
  const emitted: EmittedTally = {
    ...tallyResult,
    gh_ok: ghOk,
    snapshot_present: snapshot !== null,
    snapshot_reviewed_at: snapshot?.reviewed_at ?? null,
    tally_schema_version: TALLY_SCHEMA_VERSION,
    triggers,
  };

  process.stdout.write(`${JSON.stringify(emitted)}\n`);

  return EXIT_CODES.OK;
};
