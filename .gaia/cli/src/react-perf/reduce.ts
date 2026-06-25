/**
 * `gaia react-perf reduce <raw.json> [--frame-budget-ms <n>]`.
 *
 * The deterministic Reduce layer of the React render-performance diagnostic.
 * It reads a raw bippy render dump (~172 KB for a trivial flow), filters
 * framework noise, recomputes `memoDefeated` per record, aggregates per app
 * component, ranks by blast-radius x cost, applies a frame-budget timing
 * GATE (not a trigger), and prints a small `ReducedSummary` JSON to stdout.
 * That summary is the only thing the Phase-3 skill reads; the raw dump never
 * enters the model context.
 *
 * The signal is `memoDefeated` (a `React.memo` component that re-rendered with
 * every changed input referentially unstable), NOT the naive "nothing changed"
 * flag, which false-positives. Timing filters out the trivial; it never flags
 * a cheap memo defeat on its own.
 */
import {readFileSync} from 'node:fs';
import type {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import {
  RawDumpSchema,
  ReducedSummarySchema,
  type ChangeEntry,
  type RawDump,
  type ReactDoctorRule,
  type ReducedFinding,
  type ReducedSummary,
  type RenderRecord,
} from '../schemas/react-perf-summary.js';
import {structuredError} from '../stderr.js';
import {isFrameworkComponent} from './framework-denylist.js';

const DEFAULT_FRAME_BUDGET_MS = 16;
const UNKNOWN_NAME = 'Unknown';
// An alien dump (e.g. the react-scan shape) fails one issue per record, so an
// uncapped summary balloons stderr to hundreds of KB. The first few issues
// (the missing `meta`, the divergent record shape) already make the rejection
// unambiguous.
const MAX_ERROR_ISSUES = 6;

const HELP_TEXT = `Usage: gaia react-perf reduce <raw.json> [--frame-budget-ms <n>]

  Reduce a raw bippy render dump to a small, ranked ReducedSummary (JSON on
  stdout). Filters framework noise, recomputes memoDefeated, ranks findings by
  blast-radius x cost, and gates on the frame budget (default ${String(
    DEFAULT_FRAME_BUDGET_MS
  )}ms).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// Concise, single-line Zod summary prefixed with the offending file. Mirrors
// `schemas/zod-error.ts` but caps the issue list so a wholesale shape mismatch
// cannot flood stderr.
const summarizeDumpError = (filePath: string, error: z.ZodError): string => {
  const lines = error.issues.slice(0, MAX_ERROR_ISSUES).map((issue) => {
    const pathStr = issue.path.length === 0 ? '<root>' : issue.path.join('.');

    return `${pathStr}: ${issue.message}`;
  });

  const omitted = error.issues.length - lines.length;
  const suffix = omitted > 0 ? `; (+${String(omitted)} more issues)` : '';

  return `${filePath}: ${lines.join('; ')}${suffix}`;
};

type Aggregate = {
  componentName: string;
  isMemo: boolean;
  renderCount: number;
  memoDefeatedCount: number;
  totalSelfTime: number;
  maxTotalTime: number;
  unstableProps: Set<string>;
  unstableStateIndexes: Set<number>;
  unstablePropCount: number;
  unstableContextCount: number;
  unstableStateCount: number;
};

const compareStrings = (a: string, b: string): number => {
  if (a < b) return -1;

  return a > b ? 1 : 0;
};

const allChangeEntries = (record: RenderRecord): ChangeEntry[] => [
  ...record.propsChanged,
  ...record.stateChanged,
  ...record.contextChanged,
];

/**
 * Recompute `memoDefeated` from primitives, never trusting a precomputed
 * flag: phase update + memo + at least one change + every changed input
 * referentially unstable. A record without `isMemo` is never memoDefeated.
 */
const isMemoDefeated = (record: RenderRecord): boolean => {
  if (record.phase !== 'update' || record.isMemo !== true) return false;

  if (record.changedTotal <= 0) return false;

  const entries = allChangeEntries(record);

  return entries.length > 0 && entries.every((entry) => entry.unstable === true);
};

/**
 * Map the dominant unstable input to its static-cause cross-reference label.
 * Precedence on a tie: context, then prop, then state. State-only instability
 * and "no unstable input" both map to `null` (no clean cross-ref).
 * `no-unstable-nested-components` needs a nested-definition smell that the flat
 * records cannot surface, so it is never emitted in v1.
 */
const reactDoctorRuleFor = (aggregate: Aggregate): ReactDoctorRule | null => {
  const {unstableContextCount, unstablePropCount, unstableStateCount} = aggregate;
  const max = Math.max(unstableContextCount, unstablePropCount, unstableStateCount);

  if (max <= 0) return null;

  if (unstableContextCount === max) return 'jsx-no-constructed-context-values';

  if (unstablePropCount === max) return 'jsx-no-new-object-as-prop';

  return null;
};

const collectUnstableInputs = (aggregate: Aggregate): string[] => {
  const props = [...aggregate.unstableProps].sort(compareStrings);
  const state = [...aggregate.unstableStateIndexes]
    .sort((a, b) => a - b)
    .map((index) => `state[${String(index)}]`);
  const context = aggregate.unstableContextCount > 0 ? ['context'] : [];

  return [...props, ...state, ...context];
};

const compareFindings = (a: Aggregate, b: Aggregate): number => {
  // memoDefeated-bearing components lead; the skill leads with memoDefeated.
  const aMemo = a.memoDefeatedCount > 0 ? 1 : 0;
  const bMemo = b.memoDefeatedCount > 0 ? 1 : 0;
  if (aMemo !== bMemo) return bMemo - aMemo;

  // blast-radius x cost.
  const aScore = a.memoDefeatedCount * a.maxTotalTime;
  const bScore = b.memoDefeatedCount * b.maxTotalTime;
  if (aScore !== bScore) return bScore - aScore;

  if (a.maxTotalTime !== b.maxTotalTime) return b.maxTotalTime - a.maxTotalTime;

  if (a.renderCount !== b.renderCount) return b.renderCount - a.renderCount;

  return compareStrings(a.componentName, b.componentName);
};

/**
 * The pure reduce. Deterministic: same input + same frame budget yields a
 * byte-identical summary (stable sort, no clock or randomness).
 */
export const reduceDump = (
  dump: RawDump,
  options: {frameBudgetMs: number}
): ReducedSummary => {
  const {frameBudgetMs} = options;

  let updates = 0;
  let mounts = 0;
  let frameworkFiltered = 0;
  let unknownNameCount = 0;

  // Map preserves first-seen order; the final findings sort makes output order
  // independent of it, but it keeps aggregation deterministic regardless.
  const aggregates = new Map<string, Aggregate>();

  for (const record of dump.all) {
    if (record.phase === 'mount') mounts += 1;

    if (record.phase !== 'update') continue;

    updates += 1;

    if (record.componentName === UNKNOWN_NAME) {
      // Never silently dropped: a wall of unnamed renders is a finding in itself.
      unknownNameCount += 1;

      continue;
    }

    if (isFrameworkComponent(record.componentName)) {
      frameworkFiltered += 1;

      continue;
    }

    const aggregate =
      aggregates.get(record.componentName) ??
      {
        componentName: record.componentName,
        isMemo: false,
        renderCount: 0,
        memoDefeatedCount: 0,
        totalSelfTime: 0,
        maxTotalTime: 0,
        unstableProps: new Set<string>(),
        unstableStateIndexes: new Set<number>(),
        unstablePropCount: 0,
        unstableContextCount: 0,
        unstableStateCount: 0,
      };

    aggregate.renderCount += 1;
    aggregate.totalSelfTime += record.selfTime;
    aggregate.maxTotalTime = Math.max(aggregate.maxTotalTime, record.totalTime);
    aggregate.isMemo = aggregate.isMemo || record.isMemo === true;

    if (isMemoDefeated(record)) aggregate.memoDefeatedCount += 1;

    for (const entry of record.propsChanged) {
      if (entry.unstable) {
        aggregate.unstableProps.add(`prop:${entry.name ?? '?'}`);
        aggregate.unstablePropCount += 1;
      }
    }
    for (const entry of record.stateChanged) {
      if (entry.unstable) {
        aggregate.unstableStateIndexes.add(entry.index ?? -1);
        aggregate.unstableStateCount += 1;
      }
    }
    for (const entry of record.contextChanged) {
      if (entry.unstable) aggregate.unstableContextCount += 1;
    }

    aggregates.set(record.componentName, aggregate);
  }

  const appComponents = [...aggregates.values()];
  const memoDefeated = appComponents.reduce(
    (sum, aggregate) => sum + aggregate.memoDefeatedCount,
    0
  );

  // A finding is actionable when memoDefeated (the trigger) OR over the frame
  // budget (the gate). Plain "re-rendered with real changes" is not surfaced:
  // that is the over-optimization trap the naive flag falls into.
  const findingAggregates = appComponents
    .filter(
      (aggregate) =>
        aggregate.memoDefeatedCount > 0 || aggregate.maxTotalTime > frameBudgetMs
    )
    .sort(compareFindings);

  const findings: ReducedFinding[] = findingAggregates.map((aggregate, index) => ({
    componentName: aggregate.componentName,
    isMemo: aggregate.isMemo,
    renderCount: aggregate.renderCount,
    memoDefeatedCount: aggregate.memoDefeatedCount,
    totalSelfTime: aggregate.totalSelfTime,
    maxTotalTime: aggregate.maxTotalTime,
    exceedsFrameBudget: aggregate.maxTotalTime > frameBudgetMs,
    unstableInputs: collectUnstableInputs(aggregate),
    reactDoctorRule: reactDoctorRuleFor(aggregate),
    rank: index + 1,
  }));

  return {
    schemaVersion: 1,
    rendererVersion: dump.meta.rendererVersion,
    profilingAvailable: dump.meta.profilingAvailable,
    strictModeTimingCaveat: dump.meta.strictMode,
    totals: {
      records: dump.all.length,
      updates,
      mounts,
      frameworkFiltered,
      appComponents: appComponents.length,
      memoDefeated,
    },
    findings,
    unknownNameCount,
    stopSignal: {
      zeroAppMemoDefeated: memoDefeated === 0,
      noAppFrameBudgetBreach: appComponents.every(
        (aggregate) => aggregate.maxTotalTime <= frameBudgetMs
      ),
    },
  };
};

type ParsedArgs =
  | {kind: 'help'}
  | {kind: 'error'; code: string; message: string}
  | {kind: 'ok'; filePath: string; frameBudgetMs: number};

const parseArgs = (argv: readonly string[]): ParsedArgs => {
  let filePath: string | undefined;
  let frameBudgetMs = DEFAULT_FRAME_BUDGET_MS;

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i] as string;

    if (HELP_TOKENS.has(token)) return {kind: 'help'};

    if (token === '--frame-budget-ms') {
      const value = argv[i + 1];
      const parsed = Number(value);

      if (value === undefined || !Number.isFinite(parsed) || parsed <= 0) {
        return {
          kind: 'error',
          code: 'invalid_arguments',
          message: `--frame-budget-ms requires a positive number, got: ${String(value)}`,
        };
      }

      frameBudgetMs = parsed;
      i += 1;

      continue;
    }

    if (token.startsWith('--')) {
      return {kind: 'error', code: 'invalid_arguments', message: `unknown flag: ${token}`};
    }

    if (filePath === undefined) {
      filePath = token;

      continue;
    }

    return {
      kind: 'error',
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
    };
  }

  if (filePath === undefined) {
    return {
      kind: 'error',
      code: 'invalid_arguments',
      message: 'missing required <raw.json> path',
    };
  }

  return {kind: 'ok', filePath, frameBudgetMs};
};

export const run = (argv: readonly string[]): number => {
  const args = parseArgs(argv);

  if (args.kind === 'help') {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (args.kind === 'error') {
    structuredError({
      code: args.code,
      message: args.message,
      subcommand: 'react-perf reduce',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let raw: string;

  try {
    raw = readFileSync(args.filePath, 'utf8');
  } catch (error) {
    structuredError({
      code: 'input_unreadable',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'react-perf reduce',
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  let json: unknown;

  try {
    json = JSON.parse(raw);
  } catch (error) {
    structuredError({
      code: 'invalid_json',
      message: `${args.filePath}: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: 'react-perf reduce',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  const parsed = RawDumpSchema.safeParse(json);

  if (!parsed.success) {
    structuredError({
      code: 'invalid_dump',
      message: summarizeDumpError(args.filePath, parsed.error),
      subcommand: 'react-perf reduce',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  // Validate output before printing: the summary is a downstream contract.
  const summary = ReducedSummarySchema.parse(
    reduceDump(parsed.data, {frameBudgetMs: args.frameBudgetMs})
  );

  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);

  return EXIT_CODES.OK;
};
