/**
 * `gaia harden-ledger {list|record|is-suppressed|prune}`
 *
 * The machine-local decline ledger CLI. When an engineer declines a hardening
 * candidate the decline is recorded only on their machine (gitignored), so it
 * never vetoes the rule for a teammate. Re-surfacing is evidence-based, not a
 * timer: a declined class stays suppressed for that engineer until the window's
 * distinct-PR count for the class rises at least 3 above its snapshot at the
 * decline. That is a delta between two rolling-window snapshots, not a monotonic
 * count of PRs merged since the decline, so window churn (old PRs aging out) can
 * lower the current count and thereby delay or indefinitely prevent re-surface.
 *
 * The tally refresher READS this surface (`is-suppressed`, `prune`); the
 * `/gaia-harden` command WRITES to it (`record`) on decline. Both bind to the
 * verbs and exit-code semantics below.
 *
 * Ledger file: `.gaia/local/harden/declines.json` (gitignored). Schema and
 * atomic writer in `schemas/decline-ledger.ts`.
 */
import {EXIT_CODES} from '../exit.js';
import {
  emptyDeclineLedger,
  readDeclineLedger,
  writeDeclineLedger,
  type DeclineLedger,
} from '../schemas/decline-ledger.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia harden-ledger <subcommand> [args]

  list
    Print the decline ledger as JSON to stdout
    ({"version":1,"declines":[]} when absent).

  record --finding-class <c> --pr-count <n>
    Upsert one bounded entry keyed by finding_class (re-record overwrites the
    timestamp and PR count). One entry per class.

  is-suppressed --finding-class <c> --current-pr-count <n>
    Exit 0 (suppressed) when an entry exists and current-pr-count minus its
    declined_at_pr_count is below the re-surface threshold (3); exit 1
    (not suppressed) otherwise.

  prune --window-classes <c1,c2,...>
    Remove any decline entry whose finding_class is not in the comma-separated
    set (no qualifying evidence left in the window). Idempotent.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// Re-surface threshold: a declined class stays suppressed until the window's
// distinct-PR count for the class rises at least this far above its snapshot at
// the decline. The comparison is a window-snapshot delta, not a monotonic count
// of PRs merged since the decline, so window churn can delay or prevent
// re-surface.
const RESURFACE_THRESHOLD = 3;

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const sub = argv[0] as string;
  const rest = argv.slice(1);

  if (sub === 'list') return handleList(rest, options);
  if (sub === 'record') return handleRecord(rest, options);
  if (sub === 'is-suppressed') return handleIsSuppressed(rest, options);
  if (sub === 'prune') return handlePrune(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown harden-ledger subcommand: ${sub}`,
    subcommand: 'harden-ledger',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
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
): string | null => {
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
 * Read the ledger, translating the discriminated result into the in-memory
 * ledger or `null` on a malformed file (after surfacing a structured error).
 * A missing file resolves to the empty ledger.
 */
const loadLedger = (
  repoRoot: string,
  subcommand: string
): DeclineLedger | null => {
  const result = readDeclineLedger(repoRoot);

  if (result.status === 'malformed') {
    structuredError({
      code: 'malformed_ledger',
      message: result.error,
      subcommand: `harden-ledger ${subcommand}`,
    });

    return null;
  }

  if (result.status === 'missing') return emptyDeclineLedger();

  return result.ledger;
};

// --- list ----------------------------------------------------------------

const handleList = (argv: readonly string[], options: RunOptions): number => {
  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown argument: ${argv[0] as string}`,
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
  findingClass: string | undefined;
  prCount: number | undefined;
};

const parseRecordArgs = (argv: readonly string[]): RecordArgs | string => {
  let findingClass: string | undefined;
  let prCount: number | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--finding-class') {
      findingClass = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--pr-count') {
      prCount = parseCountFlag(argv[index + 1]);
      index += 1;

      continue;
    }

    return `unknown argument: ${token}`;
  }

  return {findingClass, prCount};
};

const handleRecord = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseRecordArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'harden-ledger record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {findingClass, prCount} = parsed;

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

  const repoRoot = resolveRoot(options, 'record');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const ledger = loadLedger(repoRoot, 'record');

  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  const declinedAt = (options.now ?? (() => new Date()))().toISOString();
  const entry = {
    declined_at: declinedAt,
    declined_at_pr_count: prCount,
    finding_class: findingClass,
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

// --- is-suppressed -------------------------------------------------------

type IsSuppressedArgs = {
  currentPrCount: number | undefined;
  findingClass: string | undefined;
};

const parseIsSuppressedArgs = (
  argv: readonly string[]
): IsSuppressedArgs | string => {
  let findingClass: string | undefined;
  let currentPrCount: number | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--finding-class') {
      findingClass = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--current-pr-count') {
      currentPrCount = parseCountFlag(argv[index + 1]);
      index += 1;

      continue;
    }

    return `unknown argument: ${token}`;
  }

  return {currentPrCount, findingClass};
};

const handleIsSuppressed = (
  argv: readonly string[],
  options: RunOptions
): number => {
  const parsed = parseIsSuppressedArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {currentPrCount, findingClass} = parsed;

  if (findingClass === undefined || findingClass === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'harden-ledger is-suppressed requires --finding-class <c>',
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (currentPrCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger is-suppressed requires --current-pr-count <n> (non-negative integer)',
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'is-suppressed');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const ledger = loadLedger(repoRoot, 'is-suppressed');

  // Fail loud on a corrupt file rather than treating it as empty (which would
  // wrongly re-surface a declined candidate).
  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  const entry = ledger.declines.find(
    (decline) => decline.finding_class === findingClass
  );

  // No entry: not suppressed (re-surface).
  if (entry === undefined) {
    structuredError({
      code: 'not_suppressed',
      finding_class: findingClass,
      reason: 'no_decline_entry',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Evidence-based, not a timer: subtract the decline-time window snapshot from
  // the current window snapshot and compare the delta against the re-surface
  // threshold. This is a window-snapshot delta, not a monotonic count of PRs
  // merged since the decline, so window churn can lower the current count and
  // delay or prevent re-surface.
  const mergedSinceDecline = currentPrCount - entry.declined_at_pr_count;
  const suppressed = mergedSinceDecline < RESURFACE_THRESHOLD;

  if (!suppressed) {
    structuredError({
      code: 'not_suppressed',
      finding_class: findingClass,
      merged_since_decline: mergedSinceDecline,
      reason: 'threshold_reached',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return EXIT_CODES.OK;
};

// --- prune ---------------------------------------------------------------

const parsePruneArgs = (
  argv: readonly string[]
): {windowClasses: string | undefined} | string => {
  let windowClasses: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--window-classes') {
      windowClasses = argv[index + 1];
      index += 1;

      continue;
    }

    return `unknown argument: ${token}`;
  }

  return {windowClasses};
};

const handlePrune = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parsePruneArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'harden-ledger prune',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {windowClasses} = parsed;

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

  const ledger = loadLedger(repoRoot, 'prune');

  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  const keep = new Set(
    windowClasses
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0)
  );

  const kept = ledger.declines.filter((decline) =>
    keep.has(decline.finding_class)
  );

  // Idempotent: only write when the prune actually removes an entry.
  if (kept.length !== ledger.declines.length) {
    writeDeclineLedger(repoRoot, {...ledger, declines: kept});
  }

  return EXIT_CODES.OK;
};
