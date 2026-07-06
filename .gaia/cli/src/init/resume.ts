/**
 * `gaia init resume --from-step <N>` handler.
 *
 * Reads `.gaia/init-state.json` and replays the canonical step sequence
 * from step N (1-indexed) onward. Steps already recorded in
 * `completed_steps` are skipped; the per-step subcommand is still
 * idempotent, but skipping at the orchestrator level keeps the surface
 * deterministic when a step's flags would not be available without
 * re-prompting the user.
 *
 * Each step's saved arguments live in `step_args` keyed by step name.
 * Resume reads them back and re-invokes the step's `run()` with the
 * original argv-shape; so a step that ran with `--title "X"` resumes
 * with the same `--title "X"`. Steps that were never run before this
 * resume cannot be replayed (their args are unknown); resume stops with
 * exit 1 and asks the maintainer to invoke the missing step manually
 * with its real flags.
 *
 * Stdout: a one-line summary per step (skipped or replayed) so the
 * maintainer can see progress. Exit codes: 0 / 1 / 2.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runBootstrapEnv} from './bootstrap-env.js';
import {run as runConfigureAutomation} from './configure-automation.js';
import {run as runConfigureI18n} from './configure-i18n.js';
import {run as runFinalize} from './finalize.js';
import {run as runRename} from './rename.js';
import {run as runStripBranding} from './strip-branding.js';
import {readState, STEP_ORDER} from './util/state.js';
import type {StepName} from './util/state.js';
import {run as runWireStatusline} from './wire-statusline.js';

const HELP_TEXT = `Usage: gaia init resume [--from-step <N>]

  Replay the gaia init sequence from step N (1-indexed). Steps already
  recorded in .gaia/init-state.json's completed_steps are skipped.

  Optional flags:
    --from-step <N>   1-indexed step to start at (default: 1).

  Steps (in order):
    1. strip-branding
    2. configure-i18n
    3. rename
    4. wire-statusline
    5. bootstrap-env
    6. configure-automation
    7. finalize

  Exit codes:
    0  resume completed
    1  user-correctable error (unknown step, missing saved args)
    2  unexpected (filesystem / step failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type Flags = {
  fromStep: number;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as `string`,
  // not `string | undefined`; check the bound explicitly instead of
  // comparing the indexed value to `undefined`.
  if (index >= argv.length) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let fromStep = 1;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--from-step') {
      const taken = takeValue(argv, index + 1, '--from-step');

      if (!taken.ok) return taken;
      const parsed = Number.parseInt(taken.value, 10);

      if (
        !Number.isInteger(parsed) ||
        parsed < 1 ||
        parsed > STEP_ORDER.length
      ) {
        return {
          message: `--from-step must be an integer between 1 and ${STEP_ORDER.length}`,
          ok: false,
        };
      }
      fromStep = parsed;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {fromStep}, ok: true};
};

type StepRunner = (
  argv: readonly string[],
  options?: {cwd?: string}
) => number | Promise<number>;

const STEP_RUNNERS: Readonly<Record<StepName, StepRunner>> = {
  'bootstrap-env': runBootstrapEnv,
  'configure-automation': runConfigureAutomation,
  'configure-i18n': runConfigureI18n,
  finalize: runFinalize,
  rename: runRename,
  'strip-branding': runStripBranding,
  'wire-statusline': runWireStatusline,
};

type StepArgvBuilder = (
  saved: Record<string, unknown> | undefined
) => null | string[];

const buildStripBrandingArgv: StepArgvBuilder = (saved) => {
  if (saved === undefined) return null;
  const {title} = saved;

  if (typeof title !== 'string') return null;

  return ['--title', title];
};

const buildConfigureI18nArgv: StepArgvBuilder = (saved) => {
  if (saved === undefined) return null;
  const {locales, strip} = saved;

  if (
    !Array.isArray(locales) ||
    locales.some((entry) => typeof entry !== 'string')
  ) {
    return null;
  }

  if (typeof strip !== 'boolean') return null;

  return [
    '--locales',
    (locales as string[]).join(','),
    '--strip',
    strip ? 'true' : 'false',
  ];
};

const buildRenameArgv: StepArgvBuilder = (saved) => {
  if (saved === undefined) return null;
  const {kebab, title} = saved;

  if (typeof title !== 'string' || typeof kebab !== 'string') return null;

  return ['--title', title, '--kebab', kebab];
};

const isToolModeValue = (value: unknown): boolean =>
  value === 'ci' || value === 'local' || value === 'off';

const buildConfigureAutomationArgv: StepArgvBuilder = (saved) => {
  if (saved === undefined) return null;
  const {
    pnpm_audit: pnpmAudit,
    stale_branches: staleBranches,
    update_deps: updateDeps,
    wiki,
  } = saved;

  if (
    !isToolModeValue(wiki) ||
    !isToolModeValue(updateDeps) ||
    !isToolModeValue(pnpmAudit) ||
    !isToolModeValue(staleBranches)
  ) {
    return null;
  }

  return [
    '--wiki',
    wiki as string,
    '--update-deps',
    updateDeps as string,
    '--pnpm-audit',
    pnpmAudit as string,
    '--stale-branches',
    staleBranches as string,
  ];
};

const buildWireStatuslineArgv: StepArgvBuilder = (saved) => {
  if (saved === undefined) return null;
  const {mode} = saved;

  if (typeof mode !== 'string') return null;

  return ['--mode', mode];
};

const STEP_ARGV_BUILDERS: Readonly<Record<StepName, StepArgvBuilder>> = {
  'bootstrap-env': () => [],
  'configure-automation': buildConfigureAutomationArgv,
  'configure-i18n': buildConfigureI18nArgv,
  finalize: () => [],
  rename: buildRenameArgv,
  'strip-branding': buildStripBrandingArgv,
  'wire-statusline': buildWireStatuslineArgv,
};

/**
 * Reconstructs the argv used the first time a step ran from its saved
 * `step_args`. Returns `null` when a required key is missing; caller
 * surfaces that as exit 1. Dispatches through a per-step builder table so
 * this stays a flat lookup regardless of how many steps exist.
 */
export const argvFromStepArgs = (
  step: StepName,
  saved: Record<string, unknown> | undefined
): null | string[] => STEP_ARGV_BUILDERS[step](saved);

type ReplayContext = {
  cwd: string;
  runners: Partial<Record<StepName, StepRunner>>;
  stepArgs: Record<string, unknown>;
};

type ReplayOutcome = {code: number; kind: 'exit'} | {kind: 'continue'};

/**
 * Replay a single non-skipped step: reconstruct its argv, run it, and
 * report whether `run` should stop (missing args / non-zero exit) or
 * continue to the next step.
 */
const replayStep = async (
  step: StepName,
  context: ReplayContext
): Promise<ReplayOutcome> => {
  const saved = context.stepArgs[step] as Record<string, unknown> | undefined;
  const stepArgv = argvFromStepArgs(step, saved);

  if (stepArgv === null) {
    structuredError({
      code: 'missing_step_args',
      message:
        `step "${step}" has no saved arguments to replay; run ` +
        `"gaia init ${step} …" with explicit flags first`,
      subcommand: 'init resume',
    });

    return {code: EXIT_CODES.UNKNOWN_SUBCOMMAND, kind: 'exit'};
  }

  const runner = context.runners[step] ?? STEP_RUNNERS[step];
  const exit = await runner(stepArgv, {cwd: context.cwd});

  if (exit !== EXIT_CODES.OK) {
    // The step itself printed a structured error to stderr.
    return {code: exit, kind: 'exit'};
  }

  process.stdout.write(`init resume: ran ${step}\n`);

  return {kind: 'continue'};
};

type RunOptions = {
  cwd?: string;
  /** Test seam: override the per-step runners. */
  runners?: Partial<Record<StepName, StepRunner>>;
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'init resume',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runners = options.runners ?? {};

  let state: ReturnType<typeof readState>;

  try {
    state = readState(cwd);
  } catch (error) {
    structuredError({
      code: 'state_read_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init resume',
    });

    return UNEXPECTED_EXIT;
  }

  const completed = new Set(state.completed_steps);

  for (
    let index = parsed.flags.fromStep - 1;
    index < STEP_ORDER.length;
    index += 1
  ) {
    const step = STEP_ORDER[index];

    if (completed.has(step)) {
      process.stdout.write(`init resume: skip ${step} (already complete)\n`);
    } else {
      // Steps replay sequentially and in order: each mutates repo state the
      // next step's idempotency check may depend on, so they cannot run
      // concurrently.
      // eslint-disable-next-line no-await-in-loop -- intentional sequential
      const outcome = await replayStep(step, {
        cwd,
        runners,
        stepArgs: state.step_args,
      });

      if (outcome.kind === 'exit') return outcome.code;
    }
  }

  return EXIT_CODES.OK;
};
