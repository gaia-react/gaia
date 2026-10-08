/**
 * `gaia harden-ledger {list|record|prune|snapshot}`
 *
 * The machine-local decline ledger CLI. When an engineer declines a hardening
 * candidate the decline is recorded only on their machine (gitignored), so it
 * never vetoes the rule for a teammate. Re-surfacing is evidence-based, not a
 * timer, and shares the same material-rise rule the `/gaia-harden` nudge
 * triggers use (`isMaterialRise`, `material-rise.ts`): a declined class stays
 * suppressed until the live count's rise over its snapshot at the decline is
 * material, measured against the audited-PR denominator on both sides. An
 * entry recorded under a different `TALLY_SCHEMA_VERSION` never suppresses,
 * because its stored count was measured against semantics the live tally no
 * longer uses.
 *
 * The tally refresher calls `checkDeclineSuppression` and `pruneDeclineLedger`
 * in process; the `/gaia-harden` command WRITES to it (`record`) on decline; a
 * completed review WRITES to the sibling `snapshot` verbs (dispatched to
 * `snapshot.ts`). The two functions write nothing to stdout or stderr: the
 * tally runs on every statusline refresh, so any output would land there.
 *
 * Ledger file: `.gaia/local/harden/declines.json` (gitignored). Schema and
 * atomic writer in `schemas/decline-ledger.ts`. The path is shared across the
 * clone's worktrees by the state registry's symlink, so a decline recorded
 * from a linked worktree lands in the main checkout's copy and survives that
 * worktree's removal.
 */
import {EXIT_CODES} from '../exit.js';
import {
  emptyDeclineLedger,
  readDeclineLedger,
  writeDeclineLedger,
} from '../schemas/decline-ledger.js';
import type {DeclineLedger} from '../schemas/decline-ledger.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from './material-rise.js';
import {runSnapshot} from './snapshot.js';

const HELP_TEXT = `Usage: gaia harden-ledger <subcommand> [args]

  list
    Print the decline ledger as JSON to stdout
    ({"version":2,"declines":[]} when absent).

  record --finding-class <c> --pr-count <n> --audited-pr-count <d>
    Upsert one bounded entry keyed by finding_class (re-record overwrites the
    timestamp, PR count, and audited-PR denominator). One entry per class.
    Stamps the entry with the live TALLY_SCHEMA_VERSION.

  prune --window-classes <c1,c2,...>
    Remove any decline entry whose finding_class is not in the comma-separated
    set (no qualifying evidence left in the window). Idempotent.

  snapshot record [args]
    Dispatches to the review-snapshot verb. See
    \`gaia harden-ledger snapshot --help\`.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// A parsed-args result is always an object (never a bare string), so a
// consuming function's return type never mixes an object shape with a
// primitive shape.
type ParseResult<T> = {error: string} | {value: T};

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

const parseCountFlag = (value: string | undefined): number | undefined => {
  if (value === undefined) return undefined;
  const parsed = Number.parseInt(value, 10);

  if (!Number.isInteger(parsed) || parsed < 0) return undefined;

  return parsed;
};

const resolveRoot = (
  options: RunOptions,
  subcommand: string
): null | string => {
  try {
    return resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia harden-ledger ${subcommand} must run inside a git repository`,
      subcommand: `harden-ledger ${subcommand}`,
    });

    return null;
  }
};

/**
 * Read the ledger as the in-memory ledger or the read error. A missing file
 * resolves to the empty ledger. Writes nothing; the caller owns reporting.
 */
const readLedger = (
  repoRoot: string
): {error: string} | {ledger: DeclineLedger} => {
  const result = readDeclineLedger(repoRoot);

  if (result.status === 'malformed') return {error: result.error};
  if (result.status === 'missing') return {ledger: emptyDeclineLedger()};

  return {ledger: result.ledger};
};

/**
 * `readLedger` for a verb: a malformed file surfaces a structured error and
 * yields `null`.
 */
const loadLedger = (
  repoRoot: string,
  subcommand: string
): DeclineLedger | null => {
  const result = readLedger(repoRoot);

  if ('error' in result) {
    structuredError({
      code: 'malformed_ledger',
      message: result.error,
      subcommand: `harden-ledger ${subcommand}`,
    });

    return null;
  }

  return result.ledger;
};

// --- list ----------------------------------------------------------------

const handleList = (argv: readonly string[], options: RunOptions): number => {
  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown argument: ${argv[0]}`,
      subcommand: 'harden-ledger list',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'list');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const ledger = loadLedger(repoRoot, 'list');

  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  process.stdout.write(`${JSON.stringify(ledger)}\n`);

  return EXIT_CODES.OK;
};

// --- record --------------------------------------------------------------

type RecordArgs = {
  auditedPrCount: number | undefined;
  findingClass: string | undefined;
  prCount: number | undefined;
};

const parseRecordArgs = (argv: readonly string[]): ParseResult<RecordArgs> => {
  let findingClass: string | undefined;
  let prCount: number | undefined;
  let auditedPrCount: number | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--finding-class') {
      findingClass = argv[index + 1];
      index += 1;
    } else if (token === '--pr-count') {
      prCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else if (token === '--audited-pr-count') {
      auditedPrCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {value: {auditedPrCount, findingClass, prCount}};
};

const handleRecord = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseRecordArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'harden-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {auditedPrCount, findingClass, prCount} = parsed.value;

  if (findingClass === undefined || findingClass === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'harden-ledger record requires --finding-class <c>',
      subcommand: 'harden-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (prCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger record requires --pr-count <n> (non-negative integer)',
      subcommand: 'harden-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (auditedPrCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger record requires --audited-pr-count <d> (non-negative integer)',
      subcommand: 'harden-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'record');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const ledger = loadLedger(repoRoot, 'record');

  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  const declinedAt = (options.now ?? (() => new Date()))().toISOString();
  const entry = {
    declined_at: declinedAt,
    declined_at_audited_pr_count: auditedPrCount,
    declined_at_pr_count: prCount,
    finding_class: findingClass,
    tally_schema_version: TALLY_SCHEMA_VERSION,
  };

  // Upsert: one bounded entry per class. Re-record overwrites in place.
  const existingIndex = ledger.declines.findIndex(
    (decline) => decline.finding_class === findingClass
  );

  if (existingIndex === -1) {
    ledger.declines.push(entry);
  } else {
    ledger.declines[existingIndex] = entry;
  }

  writeDeclineLedger(repoRoot, ledger);

  return EXIT_CODES.OK;
};

// --- suppression check ----------------------------------------------------

export type DeclineSuppression =
  | {error: string; status: 'unreadable'}
  | {
      reason: 'material_rise' | 'no_decline_entry' | 'schema_version_mismatch';
      status: 'resurface';
    }
  | {status: 'suppressed'};

/**
 * Whether a declined class stays suppressed at the live counts. A corrupt
 * ledger is `unreadable`, never `resurface`, so the caller can fail closed.
 */
export const checkDeclineSuppression = ({
  currentAuditedPrCount,
  currentPrCount,
  findingClass,
  repoRoot,
}: {
  currentAuditedPrCount: number;
  currentPrCount: number;
  findingClass: string;
  repoRoot: string;
}): DeclineSuppression => {
  const result = readLedger(repoRoot);

  if ('error' in result) return {error: result.error, status: 'unreadable'};

  const entry = result.ledger.declines.find(
    (decline) => decline.finding_class === findingClass
  );

  if (entry === undefined) {
    return {reason: 'no_decline_entry', status: 'resurface'};
  }

  // An entry recorded under a different tally schema version was measured
  // against semantics the live tally no longer uses (a different window,
  // recurrence threshold, or audited-PR predicate), so its stored count is
  // not comparable to the live one.
  if (entry.tally_schema_version !== TALLY_SCHEMA_VERSION) {
    return {reason: 'schema_version_mismatch', status: 'resurface'};
  }

  const materialRise = isMaterialRise({
    baseAuditedPrCount: entry.declined_at_audited_pr_count,
    baseCount: entry.declined_at_pr_count,
    liveAuditedPrCount: currentAuditedPrCount,
    liveCount: currentPrCount,
  });

  if (materialRise) return {reason: 'material_rise', status: 'resurface'};

  return {status: 'suppressed'};
};

// --- prune ---------------------------------------------------------------

/**
 * Drops every decline whose class is not in `windowClasses`; returns the read
 * error for a corrupt ledger and writes nothing in that case.
 */
export const pruneDeclineLedger = ({
  repoRoot,
  windowClasses,
}: {
  repoRoot: string;
  windowClasses: readonly string[];
}): {error: string} | {pruned: boolean} => {
  const result = readLedger(repoRoot);

  if ('error' in result) return {error: result.error};

  const {ledger} = result;
  const keep = new Set(windowClasses);
  const kept = ledger.declines.filter((decline) =>
    keep.has(decline.finding_class)
  );

  // Idempotent: only write when the prune actually removes an entry.
  if (kept.length === ledger.declines.length) return {pruned: false};

  writeDeclineLedger(repoRoot, {...ledger, declines: kept});

  return {pruned: true};
};

const parsePruneArgs = (
  argv: readonly string[]
): ParseResult<{windowClasses: string | undefined}> => {
  let windowClasses: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--window-classes') {
      windowClasses = argv[index + 1];
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {value: {windowClasses}};
};

const handlePrune = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parsePruneArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'harden-ledger prune',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {windowClasses} = parsed.value;

  if (windowClasses === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger prune requires --window-classes <c1,c2,...> (use an empty string to prune all)',
      subcommand: 'harden-ledger prune',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'prune');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const outcome = pruneDeclineLedger({
    repoRoot,
    windowClasses: windowClasses
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0),
  });

  if ('error' in outcome) {
    structuredError({
      code: 'malformed_ledger',
      message: outcome.error,
      subcommand: 'harden-ledger prune',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  return EXIT_CODES.OK;
};

// --- dispatch --------------------------------------------------------------

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [sub, ...rest] = argv;

  if (sub === undefined || HELP_TOKENS.has(sub)) {
    process.stdout.write(HELP_TEXT);

    return sub === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  if (sub === 'list') return handleList(rest, options);
  if (sub === 'record') return handleRecord(rest, options);
  if (sub === 'prune') return handlePrune(rest, options);
  if (sub === 'snapshot') return runSnapshot(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown harden-ledger subcommand: ${sub}`,
    subcommand: 'harden-ledger',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
