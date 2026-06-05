/**
 * `gaia harden-tally` - the deterministic, TTL-bounded recurrence tally for the
 * policy-memory loop.
 *
 * Resolves the rolling 90-day merged-PR window via `gh`, extracts each PR's
 * machine-readable findings block, counts distinct PRs per `finding_class` at
 * error/warning severity, drops classes a promoted rule already covers or the
 * decline ledger suppresses, self-cleans the ledger, and prints the candidate
 * list as JSON to stdout. The statusline refresher mirrors `candidate_count`
 * into the cache; `/gaia-harden review` re-runs this to get the live list.
 *
 * No LLM, no drafting, no writes other than (indirectly) the ledger prune. The
 * window read is the only network access and it is non-fatal: a gh failure
 * yields an empty candidate list rather than aborting the refresher.
 */
import path from 'node:path';
import {runGh, type ProcessResult} from '../ci/util/run-process.js';
import {EXIT_CODES} from '../exit.js';
import {
  computeTally,
  type TallyPrRecord,
  windowClasses,
} from './compute-tally.js';
import {coveredClassesFromRules} from './covered-classes.js';
import {
  defaultLedgerRunner,
  makeLedgerSuppressionPredicate,
  pruneLedger,
  type LedgerRunner,
} from './ledger-bridge.js';
import {parseFindingsBlock} from './parse-findings-block.js';

const HELP_TEXT = `Usage: gaia harden-tally

  Tallies recurring code-review-audit findings across the rolling 90-day
  merged-PR window and prints the candidate list as JSON. A class is a
  candidate when it recurs across >= 3 distinct PRs at error/warning severity,
  no promoted rule covers it, and the decline ledger does not suppress it.

  Network failures are non-fatal: gh errors yield an empty candidate list.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const WINDOW_DAYS = 90;

type RunOptions = {
  cwd?: string;
  runLedger?: LedgerRunner;
};

const windowStartDate = (now: Date): string => {
  const start = new Date(now.getTime() - WINDOW_DAYS * 24 * 60 * 60 * 1000);

  return start.toISOString().slice(0, 10);
};

type GhPr = {
  comments: Array<{body: string}>;
  number: number;
};

const parseGhPr = (value: unknown): GhPr | null => {
  if (typeof value !== 'object' || value === null) return null;
  const v = value as Record<string, unknown>;

  if (typeof v.number !== 'number' || !Number.isFinite(v.number)) return null;
  if (!Array.isArray(v.comments)) return null;

  const comments: Array<{body: string}> = [];

  for (const comment of v.comments) {
    if (
      typeof comment === 'object' &&
      comment !== null &&
      typeof (comment as Record<string, unknown>).body === 'string'
    ) {
      comments.push({body: (comment as Record<string, unknown>).body as string});
    }
  }

  return {comments, number: v.number};
};

/**
 * Reads the merged-PR window via gh. Returns one record per PR that carries a
 * parseable findings block (the latest such comment wins so a re-run audit
 * supersedes an earlier one). Returns an empty array on any gh failure so the
 * refresher never blocks.
 */
const fetchWindowPrs = (cwd: string, now: Date): TallyPrRecord[] => {
  const search = `merged:>=${windowStartDate(now)}`;
  const ghResult: ProcessResult = runGh(
    [
      'pr',
      'list',
      '--state',
      'merged',
      '--search',
      search,
      '--limit',
      '200',
      '--json',
      'number,comments',
    ],
    {cwd}
  );

  if (ghResult.exitCode !== 0) return [];

  let parsed: unknown;

  try {
    parsed = JSON.parse(ghResult.stdout);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) return [];

  const records: TallyPrRecord[] = [];

  for (const value of parsed) {
    const pr = parseGhPr(value);

    if (pr === null) continue;

    // The latest comment carrying a block wins (a re-run audit supersedes an
    // earlier one on the same PR).
    let findings: TallyPrRecord['findings'] | undefined;

    for (const comment of pr.comments) {
      const block = parseFindingsBlock(comment.body);

      if (block !== null) findings = block;
    }

    if (findings !== undefined) {
      records.push({findings, pr_number: pr.number});
    }
  }

  return records;
};

export const run = (argv: readonly string[], options: RunOptions = {}): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const cwd = options.cwd ?? process.cwd();
  const runLedger = options.runLedger ?? defaultLedgerRunner;
  const now = new Date();

  const prs = fetchWindowPrs(cwd, now);
  const covered = coveredClassesFromRules(
    path.join(cwd, '.claude', 'rules')
  );

  const tallyResult = computeTally({
    coveredClass: (findingClass) => covered.has(findingClass),
    prs,
    suppressedClass: makeLedgerSuppressionPredicate({cwd, runLedger}),
    windowDays: WINDOW_DAYS,
  });

  // Self-clean the ledger: drop declines whose class no longer recurs.
  pruneLedger({cwd, runLedger, windowClasses: windowClasses(prs)});

  process.stdout.write(`${JSON.stringify(tallyResult)}\n`);

  return EXIT_CODES.OK;
};
