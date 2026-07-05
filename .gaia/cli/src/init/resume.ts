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
import {readState, STEP_ORDER, type StepName} from './util/state.js';
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

type Flags = {
  fromStep: number;
};

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let fromStep = 1;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

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
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
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

/**
 * Reconstructs the argv used the first time a step ran from its saved
 * `step_args`. Returns `null` when a required key is missing; caller
 * surfaces that as exit 1.
 */
export const argvFromStepArgs = (
  step: StepName,
  saved: Record<string, unknown> | undefined
): string[] | null => {
  if (step === 'finalize' || step === 'bootstrap-env') return [];

  if (saved === undefined) return null;

  if (step === 'strip-branding') {
    const title = saved.title;

    if (typeof title !== 'string') return null;

    return ['--title', title];
  }

  if (step === 'configure-i18n') {
    const locales = saved.locales;
    const strip = saved.strip;

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
  }

  if (step === 'rename') {
    const title = saved.title;
    const kebab = saved.kebab;

    if (typeof title !== 'string' || typeof kebab !== 'string') return null;

    return ['--title', title, '--kebab', kebab];
  }

  if (step === 'configure-automation') {
    const wiki = saved.wiki;
    const updateDeps = saved.update_deps;
    const pnpmAudit = saved.pnpm_audit;
    const staleBranches = saved.stale_branches;
    const valid = (value: unknown): boolean =>
      value === 'ci' || value === 'local' || value === 'off';

    if (
      !valid(wiki) ||
      !valid(updateDeps) ||
      !valid(pnpmAudit) ||
      !valid(staleBranches)
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
  }

  // wire-statusline
  const mode = saved.mode;

  if (typeof mode !== 'string') return null;

  return ['--mode', mode];
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
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
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
    const step = STEP_ORDER[index] as StepName;

    if (completed.has(step)) {
      process.stdout.write(`init resume: skip ${step} (already complete)\n`);
      continue;
    }

    const saved = state.step_args[step] as Record<string, unknown> | undefined;
    const stepArgv = argvFromStepArgs(step, saved);

    if (stepArgv === null) {
      structuredError({
        code: 'missing_step_args',
        message:
          `step "${step}" has no saved arguments to replay; run ` +
          `"gaia init ${step} …" with explicit flags first`,
        subcommand: 'init resume',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    const runner = runners[step] ?? STEP_RUNNERS[step];
    const exit = await runner(stepArgv, {cwd});

    if (exit !== EXIT_CODES.OK) {
      // The step itself printed a structured error to stderr.
      return exit;
    }

    process.stdout.write(`init resume: ran ${step}\n`);
  }

  return EXIT_CODES.OK;
};
