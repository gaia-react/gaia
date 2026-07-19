/**
 * `gaia-maintainer release manifest` CLI: flag grammar. Argv parsing,
 * flag-combination validation, and the `--help` / usage text.
 *
 * Consumed by `manifest-cli.ts`, which owns the check/emit execution behind
 * the flags this module parses.
 */
import type {WithholdAnswer} from './manifest-answers.js';

export const HELP_TEXT = `Usage: gaia-maintainer release manifest [--out <path>] [--stdout]
                                       [--ship <path>]...
                                       [--withhold <path> --category <N> --reason <text>]...
                                       [--allow-undecided]
       gaia-maintainer release manifest --check [--json]

  Regenerate .gaia/manifest.json. Walks git ls-files, subtracts
  release-exclude patterns and adopter-owned sentinels, classifies the
  remainder, and writes a sorted JSON manifest.

  Refuses, in every output mode, to produce a manifest while any file that
  would newly ship lacks an explicit answer. Answer each one with --ship or
  --withhold, or waive the accounting with --allow-undecided.

  Flags:
    --ship <path>      Answer <path> as shipping. Repeatable.
    --withhold <path>  Answer <path> as withheld: appends it to
                       .gaia/release-exclude. Repeatable. Each --withhold
                       must be closed by exactly one --category and exactly
                       one --reason before the next one.
    --category <N>     Numbered release-exclude category the open --withhold
                       is filed under.
    --reason <text>    One-line rationale, written as the comment directly
                       above the withheld path.
    --allow-undecided  Waive the answer requirement; every unanswered file
                       ships. The escape hatch for bootstrapping a manifest
                       and for unattended regeneration.
    --out <path>       Override output path (default: .gaia/manifest.json).
    --stdout           Print manifest JSON to stdout instead of writing the file.
    --check            Verify the committed manifest matches what the
                       classifier would produce against the current source,
                       lint classifier sets against release-exclude for
                       dead-code overlap, and lint every owned .sh-bearing
                       directory against the scrub maintainer-paths scope and
                       runtime-deps's SCAN_GLOBS. Exits non-zero on drift,
                       overlap, or a scan-scope gap. Read-only: incompatible
                       with every flag above.
    --json             (with --check) Emit a structured JSON drift report.

  Exit codes:
    0  success / check clean
    1  unanswered or invalid answers / user-correctable error / check found
       drift or overlap
    2  unexpected (filesystem / git failure)
`;

export const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type FlagParseResult = FlagParseFailure | FlagParseSuccess;

export type Flags = {
  allowUndecided: boolean;
  check: boolean;
  json: boolean;
  outPath: string | undefined;
  ships: string[];
  stdout: boolean;
  withholds: WithholdAnswer[];
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

/**
 * A `--withhold <path>` that has not yet been closed by its `--category` and
 * `--reason`. The next `--withhold`, or the end of argv, closes it.
 */
type PendingWithhold = {
  category: number | undefined;
  path: string;
  reason: string | undefined;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `.at()` (unlike bracket indexing) types its result `string | undefined`,
  // which honestly reflects that `index` can run past the end of argv.
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

/** Returns an error message, or `undefined` once the record is banked. */
const closeWithhold = (
  pending: PendingWithhold | undefined,
  withholds: WithholdAnswer[]
): string | undefined => {
  if (pending === undefined) return undefined;

  if (pending.category === undefined)
    return `--withhold ${pending.path} requires a --category`;

  if (pending.reason === undefined)
    return `--withhold ${pending.path} requires a --reason`;

  withholds.push({
    category: pending.category,
    path: pending.path,
    reason: pending.reason,
  });

  return undefined;
};

/** Accumulator threaded through the flag handlers below. */
type ParseState = {
  allowUndecided: boolean;
  check: boolean;
  json: boolean;
  outPath: string | undefined;
  pending: PendingWithhold | undefined;
  ships: string[];
  stdout: boolean;
  withholds: WithholdAnswer[];
};

/** Each returns an error message, or `undefined` on success. */
type ValueFlagHandler = (
  state: ParseState,
  value: string
) => string | undefined;

const applyCategory: ValueFlagHandler = (state, value) => {
  if (state.pending === undefined)
    return '--category requires a preceding --withhold';

  if (state.pending.category !== undefined)
    return `--withhold ${state.pending.path} carries more than one --category`;

  if (!/^\d+$/.test(value) || Number(value) === 0)
    return `--category must be a positive integer, got: ${value}`;

  state.pending.category = Number(value);

  return undefined;
};

const applyReason: ValueFlagHandler = (state, value) => {
  if (state.pending === undefined)
    return '--reason requires a preceding --withhold';

  if (state.pending.reason !== undefined)
    return `--withhold ${state.pending.path} carries more than one --reason`;

  state.pending.reason = value;

  return undefined;
};

const openPendingWithhold: ValueFlagHandler = (state, value) => {
  const closeError = closeWithhold(state.pending, state.withholds);

  if (closeError !== undefined) return closeError;

  state.pending = {category: undefined, path: value, reason: undefined};

  return undefined;
};

const VALUE_FLAGS: Readonly<Partial<Record<string, ValueFlagHandler>>> = {
  '--category': applyCategory,
  '--out': (state, value) => {
    state.outPath = value;

    return undefined;
  },
  '--reason': applyReason,
  '--ship': (state, value) => {
    state.ships.push(value);

    return undefined;
  },
  '--withhold': openPendingWithhold,
};

const BARE_FLAGS: Readonly<
  Partial<Record<string, (state: ParseState) => void>>
> = {
  '--allow-undecided': (state) => {
    state.allowUndecided = true;
  },
  '--check': (state) => {
    state.check = true;
  },
  '--json': (state) => {
    state.json = true;
  },
  '--stdout': (state) => {
    state.stdout = true;
  },
};

/**
 * Own-property lookup. A bare `Record` index resolves every `Object.prototype`
 * member (`toString`, `constructor`, `__proto__`, …) to a truthy value, so an
 * argv token that happens to name one would slip past the unknown-flag guard:
 * the six method names would be accepted and silently ignored, and `__proto__`
 * would resolve to a non-callable and crash the parse.
 */
const lookUpFlagHandler = <Handler>(
  table: Readonly<Partial<Record<string, Handler>>>,
  token: string
): Handler | undefined =>
  Object.hasOwn(table, token) ? table[token] : undefined;

const validateFlagCombination = (state: ParseState): FlagParseResult => {
  const {allowUndecided, check, json, outPath, ships, stdout, withholds} =
    state;
  const hasAnswers = allowUndecided || ships.length > 0 || withholds.length > 0;

  // `--check` stays read-only: it answers nothing and writes nothing.
  if (check && (outPath !== undefined || stdout || hasAnswers)) {
    return {
      message:
        '--check is incompatible with --out / --stdout / --ship / --withhold / --allow-undecided',
      ok: false,
    };
  }

  if (!check && json) {
    return {message: '--json requires --check', ok: false};
  }

  return {
    flags: {allowUndecided, check, json, outPath, ships, stdout, withholds},
    ok: true,
  };
};

export const parseFlags = (argv: readonly string[]): FlagParseResult => {
  const state: ParseState = {
    allowUndecided: false,
    check: false,
    json: false,
    outPath: undefined,
    pending: undefined,
    ships: [],
    stdout: false,
    withholds: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const bare = lookUpFlagHandler(BARE_FLAGS, token);
    const valued = lookUpFlagHandler(VALUE_FLAGS, token);

    if (bare !== undefined) {
      bare(state);
    } else if (valued === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;

      const error = valued(state, taken.value);

      if (error !== undefined) return {message: error, ok: false};

      index += 1;
    }
  }

  // The last `--withhold` is closed by the end of argv rather than by a
  // following one.
  const closeError = closeWithhold(state.pending, state.withholds);

  if (closeError !== undefined) return {message: closeError, ok: false};

  return validateFlagCombination(state);
};
