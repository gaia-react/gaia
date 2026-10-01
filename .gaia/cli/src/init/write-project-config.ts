/**
 * The scaffold-time writer of `.gaia/project.json`. `/gaia-init` collects
 * the values with AskUserQuestion and passes them through as flags.
 *
 * `--sandbox-recommended` is required so an adopter who skipped the prompt
 * cannot be silently configured; `--isolation-policy` is optional because
 * leaving the key absent keeps `/setup-gaia`'s isolation question live.
 *
 * Idempotent: re-running with the same flags rewrites byte-identical content.
 */
import {EXIT_CODES} from '../exit.js';
import {
  isIsolationPolicy,
  ISOLATION_POLICIES,
} from '../schemas/project-config.js';
import type {IsolationPolicy} from '../schemas/project-config.js';
import {structuredError} from '../stderr.js';
import {takeValue} from '../util/argv.js';
import {
  ProjectConfigError,
  updateProjectConfig,
} from '../util/project-config-write.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = String.raw`Usage: gaia init write-project-config \
  --sandbox-recommended <true|false> \
  [--isolation-policy <${ISOLATION_POLICIES.join('|')}>]

  Write .gaia/project.json with the owner's Bash-sandbox recommendation and,
  when given, the team's git isolation policy. Creates the file when absent
  and keeps any key already in it.

  Required flags:
    --sandbox-recommended <true|false>

  Optional flags:
    --isolation-policy <${ISOLATION_POLICIES.join('|')}>
      Omitted entirely when the flag is absent (no policy on file).

  Exit codes:
    0   success (no stdout)
    1   user-correctable error (missing/invalid flag)
    11  schema violation (the merged config failed validation)
    30  existing .gaia/project.json is malformed
    2   unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'write-project-config';
const SUBCOMMAND = 'init write-project-config';
const SANDBOX_RECOMMENDED_FLAG = '--sandbox-recommended';
const ISOLATION_POLICY_FLAG = '--isolation-policy';

type Failure = {message: string; ok: false};

type Flags = {
  isolationPolicy: IsolationPolicy | undefined;
  sandboxRecommended: boolean;
};

const takeSandboxRecommended = (
  argv: readonly string[],
  index: number,
  current: boolean | undefined
): Failure | {ok: true; value: boolean} => {
  if (current !== undefined) {
    return {
      message: `${SANDBOX_RECOMMENDED_FLAG} specified twice`,
      ok: false,
    };
  }

  const taken = takeValue(argv, index, SANDBOX_RECOMMENDED_FLAG);

  if (!taken.ok) return taken;

  if (taken.value !== 'true' && taken.value !== 'false') {
    return {
      message: `${SANDBOX_RECOMMENDED_FLAG} must be one of: true, false`,
      ok: false,
    };
  }

  return {ok: true, value: taken.value === 'true'};
};

const takeIsolationPolicy = (
  argv: readonly string[],
  index: number,
  current: IsolationPolicy | undefined
): Failure | {ok: true; value: IsolationPolicy} => {
  if (current !== undefined) {
    return {message: `${ISOLATION_POLICY_FLAG} specified twice`, ok: false};
  }

  const taken = takeValue(argv, index, ISOLATION_POLICY_FLAG);

  if (!taken.ok) return taken;

  if (!isIsolationPolicy(taken.value)) {
    return {
      message: `${ISOLATION_POLICY_FLAG} must be one of: ${ISOLATION_POLICIES.join(', ')}`,
      ok: false,
    };
  }

  return {ok: true, value: taken.value};
};

const parseFlags = (
  argv: readonly string[]
): Failure | {flags: Flags; ok: true} => {
  let sandboxRecommended: boolean | undefined;
  let isolationPolicy: IsolationPolicy | undefined;

  for (let index = 0; index < argv.length; index += 2) {
    const token = argv[index];

    if (token === SANDBOX_RECOMMENDED_FLAG) {
      const taken = takeSandboxRecommended(argv, index + 1, sandboxRecommended);

      if (!taken.ok) return taken;
      sandboxRecommended = taken.value;
    } else if (token === ISOLATION_POLICY_FLAG) {
      const taken = takeIsolationPolicy(argv, index + 1, isolationPolicy);

      if (!taken.ok) return taken;
      isolationPolicy = taken.value;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  if (sandboxRecommended === undefined) {
    return {message: `${SANDBOX_RECOMMENDED_FLAG} is required`, ok: false};
  }

  return {flags: {isolationPolicy, sandboxRecommended}, ok: true};
};

const writeProjectConfig = (cwd: string, flags: Flags): number => {
  const {isolationPolicy, sandboxRecommended} = flags;

  try {
    // The isolation key is left out of the patch, not set to undefined, so a
    // value already on file is never cleared by omitting the flag.
    updateProjectConfig(cwd, {
      sandbox_recommended: sandboxRecommended,
      ...(isolationPolicy === undefined ?
        {}
      : {isolation_policy: isolationPolicy}),
    });
  } catch (error) {
    const kind = error instanceof ProjectConfigError ? error.kind : undefined;
    const message = error instanceof Error ? error.message : String(error);

    if (kind === 'malformed') {
      structuredError({
        code: 'config_malformed',
        message,
        subcommand: SUBCOMMAND,
      });

      return EXIT_CODES.CONFIG_INVALID;
    }

    if (kind === 'invalid_value') {
      structuredError({
        code: 'schema_violation',
        message,
        subcommand: SUBCOMMAND,
      });

      return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
    }

    structuredError({
      code: 'write_project_config_failed',
      message,
      subcommand: SUBCOMMAND,
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const {isolationPolicy, sandboxRecommended} = parsed.flags;
  const writeExit = writeProjectConfig(cwd, parsed.flags);

  if (writeExit !== EXIT_CODES.OK) return writeExit;

  try {
    markStepCompleted(cwd, STEP_NAME, {
      ...(isolationPolicy === undefined ?
        {}
      : {isolation_policy: isolationPolicy}),
      sandbox_recommended: sandboxRecommended,
    });
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
