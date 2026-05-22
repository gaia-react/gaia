/**
 * `gaia setup mark-step <step>` handler.
 *
 * Records a setup step as complete in `.gaia/local/setup-state.json`.
 * Idempotent — re-running with the same step is a no-op. Creates the
 * state file lazily (with `started_at` stamped to "now") on first call.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  readStateFile,
  resolveMainWorktreeRoot,
  SETUP_STEPS,
  type SetupStep,
  type SetupState,
  writeStateFile,
} from './util/state-file.js';

const HELP_TEXT = `Usage: gaia setup mark-step <step>

  <step> must be one of: ${SETUP_STEPS.join(' | ')}

  Records the step as complete in .gaia/local/setup-state.json. Creates
  the state file on first invocation (stamping started_at to now).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  /** Override "now" for deterministic tests. */
  now?: () => Date;
};

const isSetupStep = (value: string): value is SetupStep =>
  (SETUP_STEPS as readonly string[]).includes(value);

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const first = argv[0] as string;

  if (HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (argv.length !== 1) {
    structuredError({
      code: 'invalid_arguments',
      message: 'mark-step requires exactly <step>',
      subcommand: 'setup mark-step',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!isSetupStep(first)) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown step "${first}"; must be one of ${SETUP_STEPS.join(', ')}`,
      subcommand: 'setup mark-step',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveMainWorktreeRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup mark-step must run inside a git repository',
      subcommand: 'setup mark-step',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  const isoNow = nowDate.toISOString();

  let state;

  try {
    state = readStateFile(repoRoot);
  } catch (error) {
    structuredError({
      code: 'state_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'setup mark-step',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const next: SetupState = state ?? {
    completed_at: null,
    completed_steps: [],
    started_at: isoNow,
    version: 1,
  };

  if (!next.completed_steps.includes(first)) {
    next.completed_steps = [...next.completed_steps, first];
  }

  writeStateFile(repoRoot, next);

  process.stdout.write(
    `${JSON.stringify({
      code: 'setup_step_recorded',
      pending: SETUP_STEPS.filter(
        (step) => !next.completed_steps.includes(step)
      ),
      step: first,
    })}\n`
  );

  return EXIT_CODES.OK;
};
