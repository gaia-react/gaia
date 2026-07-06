import type {z} from 'zod';
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
import {EXIT_CODES} from '../exit.js';
import {
  RawDumpSchema,
  ReducedSummarySchema,
} from '../schemas/react-perf-summary.js';
import type {
  ChangeEntry,
  RawDump,
  ReactDoctorRule,
  ReducedFinding,
  ReducedSummary,
  RenderRecord,
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
    const pathString =
      issue.path.length === 0 ? '<root>' : issue.path.join('.');

    return `${pathString}: ${issue.message}`;
  });

  const omitted = error.issues.length - lines.length;
  const suffix = omitted > 0 ? `; (+${String(omitted)} more issues)` : '';

  return `${filePath}: ${lines.join('; ')}${suffix}`;
};

type Aggregate = {
  componentName: string;
  isMemo: boolean;
  maxTotalTime: number;
  memoDefeatedCount: number;
  renderCount: number;
  totalSelfTime: number;
  unstableContextCount: number;
  unstablePropCount: number;
  unstableProps: Set<string>;
  unstableStateCount: number;
  unstableStateIndexes: Set<number>;
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

  return entries.length > 0 && entries.every((entry) => entry.unstable);
};

/**
 * Map the dominant unstable input to its static-cause cross-reference label.
 * Precedence on a tie: context, then prop, then state. State-only instability
 * and "no unstable input" both map to `null` (no clean cross-ref).
 * `no-unstable-nested-components` needs a nested-definition smell that the flat
 * records cannot surface, so it is never emitted in v1.
 */
const reactDoctorRuleFor = (aggregate: Aggregate): null | ReactDoctorRule => {
  const {unstableContextCount, unstablePropCount, unstableStateCount} =
    aggregate;
  const max = Math.max(
    unstableContextCount,
    unstablePropCount,
    unstableStateCount
  );

  if (max <= 0) return null;

  if (unstableContextCount === max) return 'jsx-no-constructed-context-values';

  if (unstablePropCount === max) return 'jsx-no-new-object-as-prop';

  return null;
};

const collectUnstableInputs = (aggregate: Aggregate): string[] => {
  // Bound to a variable before sorting: canonical/no-use-extend-native's
  // proto-method database predates ES2023 and does not recognize
  // `toSorted` on an inline array-spread expression.
  const unstableProps = [...aggregate.unstableProps];
  const props = unstableProps.toSorted(compareStrings);
  const unstableStateIndexes = [...aggregate.unstableStateIndexes];
  const state = unstableStateIndexes
    .toSorted((a, b) => a - b)
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
/**
 * Fold one `update`-phase, non-framework render record into its component's
 * running aggregate (creating the aggregate on first sight). Extracted so
 * `reduceDump`'s own per-record dispatch stays flat.
 */
const accumulateRecord = (
  record: RenderRecord,
  aggregates: Map<string, Aggregate>
): void => {
  const aggregate = aggregates.get(record.componentName) ?? {
    componentName: record.componentName,
    isMemo: false,
    maxTotalTime: 0,
    memoDefeatedCount: 0,
    renderCount: 0,
    totalSelfTime: 0,
    unstableContextCount: 0,
    unstablePropCount: 0,
    unstableProps: new Set<string>(),
    unstableStateCount: 0,
    unstableStateIndexes: new Set<number>(),
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
};

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

    if (record.phase === 'update') {
      updates += 1;

      if (record.componentName === UNKNOWN_NAME) {
        // Never silently dropped: a wall of unnamed renders is a finding
        // in itself.
        unknownNameCount += 1;
      } else if (isFrameworkComponent(record.componentName)) {
        frameworkFiltered += 1;
      } else {
        accumulateRecord(record, aggregates);
      }
    }
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
        aggregate.memoDefeatedCount > 0 ||
        aggregate.maxTotalTime > frameBudgetMs
    )
    .toSorted(compareFindings);

  const findings: ReducedFinding[] = findingAggregates.map(
    (aggregate, index) => ({
      componentName: aggregate.componentName,
      exceedsFrameBudget: aggregate.maxTotalTime > frameBudgetMs,
      isMemo: aggregate.isMemo,
      maxTotalTime: aggregate.maxTotalTime,
      memoDefeatedCount: aggregate.memoDefeatedCount,
      rank: index + 1,
      reactDoctorRule: reactDoctorRuleFor(aggregate),
      renderCount: aggregate.renderCount,
      totalSelfTime: aggregate.totalSelfTime,
      unstableInputs: collectUnstableInputs(aggregate),
    })
  );

  return {
    findings,
    profilingAvailable: dump.meta.profilingAvailable,
    rendererVersion: dump.meta.rendererVersion,
    schemaVersion: 1,
    stopSignal: {
      noAppFrameBudgetBreach: appComponents.every(
        (aggregate) => aggregate.maxTotalTime <= frameBudgetMs
      ),
      zeroAppMemoDefeated: memoDefeated === 0,
    },
    strictModeTimingCaveat: dump.meta.strictMode,
    totals: {
      appComponents: appComponents.length,
      frameworkFiltered,
      memoDefeated,
      mounts,
      records: dump.all.length,
      updates,
    },
    unknownNameCount,
  };
};

type ParsedArgs =
  | {code: string; kind: 'error'; message: string}
  | {filePath: string; frameBudgetMs: number; kind: 'ok'}
  | {kind: 'help'};

const parseArgs = (argv: readonly string[]): ParsedArgs => {
  let filePath: string | undefined;
  let frameBudgetMs = DEFAULT_FRAME_BUDGET_MS;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (HELP_TOKENS.has(token)) return {kind: 'help'};

    if (token === '--frame-budget-ms') {
      // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as
      // `string`, not `string | undefined`; check the bound explicitly
      // instead of comparing the indexed value to `undefined`.
      if (index + 1 >= argv.length) {
        return {
          code: 'invalid_arguments',
          kind: 'error',
          message:
            '--frame-budget-ms requires a positive number, got: undefined',
        };
      }

      const value = argv[index + 1];
      const parsed = Number(value);

      if (!Number.isFinite(parsed) || parsed <= 0) {
        return {
          code: 'invalid_arguments',
          kind: 'error',
          message: `--frame-budget-ms requires a positive number, got: ${value}`,
        };
      }

      frameBudgetMs = parsed;
      index += 1;
    } else if (token.startsWith('--')) {
      return {
        code: 'invalid_arguments',
        kind: 'error',
        message: `unknown flag: ${token}`,
      };
    } else if (filePath === undefined) {
      filePath = token;
    } else {
      return {
        code: 'invalid_arguments',
        kind: 'error',
        message: `unexpected argument: ${token}`,
      };
    }
  }

  if (filePath === undefined) {
    return {
      code: 'invalid_arguments',
      kind: 'error',
      message: 'missing required <raw.json> path',
    };
  }

  return {filePath, frameBudgetMs, kind: 'ok'};
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
