/**
 * `gaia harden-ledger {list|record|is-suppressed|prune|snapshot}`
 *
 * The machine-local decline ledger CLI. When an engineer declines a hardening
 * candidate the decline is recorded only on their machine (gitignored), so it
 * never vetoes the rule for a teammate. Re-surfacing is evidence-based, not a
 * timer, and shares the same material-rise rule the `/gaia-harden` nudge
 * triggers use (`isMaterialRise`, `material-rise.ts`): a declined class stays
 * suppressed until the live count's rise over its snapshot at the decline is
 * material, measured against the audited-PR denominator on both sides. An
 * entry recorded before the denominator existed, or under a different
 * `TALLY_SCHEMA_VERSION`, is legacy and never suppresses, because a raw count
 * with no denominator cannot be compared to a live share honestly.
 *
 * The tally refresher READS this surface (`is-suppressed`, `prune`); the
 * `/gaia-harden` command WRITES to it (`record`) on decline; a completed
 * review WRITES to the sibling `snapshot` verbs (dispatched to
 * `snapshot.ts`). All three bind to the verbs and exit-code semantics below.
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

  is-suppressed --finding-class <c> --current-pr-count <n> --current-audited-pr-count <d>
    Exit 0 (suppressed) when an entry exists, is version-2-complete, was
    recorded under the live TALLY_SCHEMA_VERSION, and the rise from its
    snapshot to the current count/denominator is not material (see
    material-rise.ts). Exit 1 (not suppressed) otherwise. Exit 2
    (INVALID_ARGUMENTS) on a malformed call.

  prune --window-classes <c1,c2,...>
    Remove any decline entry whose finding_class is not in the comma-separated
    set (no qualifying evidence left in the window). Idempotent.

  snapshot <record|show> [args]
    Dispatches to the review-snapshot verbs. See
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

// --- is-suppressed -------------------------------------------------------

type IsSuppressedArgs = {
  currentAuditedPrCount: number | undefined;
  currentPrCount: number | undefined;
  findingClass: string | undefined;
};

const parseIsSuppressedArgs = (
  argv: readonly string[]
): ParseResult<IsSuppressedArgs> => {
  let findingClass: string | undefined;
  let currentPrCount: number | undefined;
  let currentAuditedPrCount: number | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--finding-class') {
      findingClass = argv[index + 1];
      index += 1;
    } else if (token === '--current-pr-count') {
      currentPrCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else if (token === '--current-audited-pr-count') {
      currentAuditedPrCount = parseCountFlag(argv[index + 1]);
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {value: {currentAuditedPrCount, currentPrCount, findingClass}};
};

const handleIsSuppressed = (
  argv: readonly string[],
  options: RunOptions
): number => {
  const parsed = parseIsSuppressedArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const {currentAuditedPrCount, currentPrCount, findingClass} = parsed.value;

  if (findingClass === undefined || findingClass === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'harden-ledger is-suppressed requires --finding-class <c>',
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  if (currentPrCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger is-suppressed requires --current-pr-count <n> (non-negative integer)',
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  if (currentAuditedPrCount === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message:
        'harden-ledger is-suppressed requires --current-audited-pr-count <d> (non-negative integer)',
      subcommand: 'harden-ledger is-suppressed',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const repoRoot = resolveRoot(options, 'is-suppressed');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  const ledger = loadLedger(repoRoot, 'is-suppressed');

  // Fail loud on a corrupt file rather than treating it as empty (which would
  // wrongly re-surface a declined candidate).
  if (ledger === null) return EXIT_CODES.CONFIG_INVALID;

  const notSuppressed = (reason: string): number => {
    structuredError({
      code: 'not_suppressed',
      finding_class: findingClass,
      reason,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  };

  const entry = ledger.declines.find(
    (decline) => decline.finding_class === findingClass
  );

  // No entry: not suppressed (re-surface).
  if (entry === undefined) {
    return notSuppressed('no_decline_entry');
  }

  // A legacy entry (recorded before the denominator existed, or read from a
  // version-1 file) carries no honest live share to compare against, so it
  // never suppresses.
  if (
    entry.declined_at_audited_pr_count === undefined ||
    entry.tally_schema_version === undefined
  ) {
    return notSuppressed('legacy_entry');
  }

  // An entry recorded under a different tally schema version was measured
  // against semantics the live tally no longer uses (a different window,
  // recurrence threshold, or audited-PR predicate), so its stored count is
  // not comparable to the live one.
  if (entry.tally_schema_version !== TALLY_SCHEMA_VERSION) {
    return notSuppressed('schema_version_mismatch');
  }

  const suppressed = !isMaterialRise({
    baseAuditedPrCount: entry.declined_at_audited_pr_count,
    baseCount: entry.declined_at_pr_count,
    liveAuditedPrCount: currentAuditedPrCount,
    liveCount: currentPrCount,
  });

  if (!suppressed) {
    return notSuppressed('material_rise');
  }

  return EXIT_CODES.OK;
};

// --- prune ---------------------------------------------------------------

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
  if (sub === 'is-suppressed') return handleIsSuppressed(rest, options);
  if (sub === 'prune') return handlePrune(rest, options);
  if (sub === 'snapshot') return runSnapshot(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown harden-ledger subcommand: ${sub}`,
    subcommand: 'harden-ledger',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
