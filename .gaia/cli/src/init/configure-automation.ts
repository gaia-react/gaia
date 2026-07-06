/**
 * `gaia init configure-automation` handler.
 *
 * Codifies the Phase A scaffold step of `/gaia-init`. Writes
 * `.gaia/automation.json` with the user's tool-mode selections and
 * `setup_complete: false`. Phase B (`/setup-gaia`) flips
 * `setup_complete` to `true` after the user creates the GitHub repo
 * and pushes.
 *
 * Headless: the skill prose collects values via AskUserQuestion and
 * passes them through as flags. No defaults at the CLI layer; every
 * flag is required so an adopter who skipped the prompt cannot be
 * silently configured.
 *
 * Idempotent: re-running with the same flags overwrites the file with
 * byte-identical content. The atomic temp + rename mirrors the
 * surrounding init handlers (`state.ts`, `finalize.ts`).
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2 / 11.
 */
import {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import type {AutomationConfig} from '../schemas/automation-config.js';
import {writeAutomationConfig} from '../setup-ci/util/automation-write.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = String.raw`Usage: gaia init configure-automation \
  --wiki <ci|local|off> \
  --update-deps <ci|local|off> \
  --pnpm-audit <ci|local|off> \
  --stale-branches <ci|local|off>

  Write .gaia/automation.json with the user's tool-mode selections and
  setup_complete: false. Phase A of GAIA CI; no GitHub repo or workflow
  YAML required.

  Required flags:
    --wiki <ci|local|off>
    --update-deps <ci|local|off>
    --pnpm-audit <ci|local|off>
    --stale-branches <ci|local|off>

  Exit codes:
    0   success (no stdout)
    1   user-correctable error (missing/invalid flag)
    11  schema violation (internal: built config failed schema parse)
    2   unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'configure-automation';
const SUBCOMMAND = 'init configure-automation';

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
  pnpmAudit: ToolMode;
  staleBranches: ToolMode;
  updateDeps: ToolMode;
  wiki: ToolMode;
};

type ToolMode = 'ci' | 'local' | 'off';

const isToolMode = (value: string): value is ToolMode =>
  value === 'ci' || value === 'local' || value === 'off';

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

const takeMode = (
  argv: readonly string[],
  index: number,
  flag: string,
  current: ToolMode | undefined
): {message: string; ok: false} | {mode: ToolMode; ok: true} => {
  if (current !== undefined) {
    return {message: `${flag} specified twice`, ok: false};
  }

  const taken = takeValue(argv, index, flag);

  if (!taken.ok) return taken;

  if (!isToolMode(taken.value)) {
    return {message: `${flag} must be one of: ci, local, off`, ok: false};
  }

  return {mode: taken.value, ok: true};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let wiki: ToolMode | undefined;
  let updateDeps: ToolMode | undefined;
  let pnpmAudit: ToolMode | undefined;
  let staleBranches: ToolMode | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--wiki') {
      const taken = takeMode(argv, index + 1, '--wiki', wiki);

      if (!taken.ok) return taken;
      wiki = taken.mode;
      index += 1;
      continue;
    }

    if (token === '--update-deps') {
      const taken = takeMode(argv, index + 1, '--update-deps', updateDeps);

      if (!taken.ok) return taken;
      updateDeps = taken.mode;
      index += 1;
      continue;
    }

    if (token === '--pnpm-audit') {
      const taken = takeMode(argv, index + 1, '--pnpm-audit', pnpmAudit);

      if (!taken.ok) return taken;
      pnpmAudit = taken.mode;
      index += 1;
      continue;
    }

    if (token === '--stale-branches') {
      const taken = takeMode(
        argv,
        index + 1,
        '--stale-branches',
        staleBranches
      );

      if (!taken.ok) return taken;
      staleBranches = taken.mode;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (wiki === undefined) return {message: '--wiki is required', ok: false};
  if (updateDeps === undefined)
    return {message: '--update-deps is required', ok: false};

  if (pnpmAudit === undefined) {
    return {message: '--pnpm-audit is required', ok: false};
  }

  if (staleBranches === undefined) {
    return {message: '--stale-branches is required', ok: false};
  }

  return {flags: {pnpmAudit, staleBranches, updateDeps, wiki}, ok: true};
};

const buildConfig = (flags: Flags): AutomationConfig => ({
  pnpm_audit: {mode: flags.pnpmAudit, schedule: 'daily'},
  setup_complete: false,
  setup_opted_out: false,
  stale_branches: {mode: flags.staleBranches, schedule: 'monthly'},
  update_deps: {mode: flags.updateDeps, schedule: 'weekly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: flags.wiki},
});

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
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
  const config = buildConfig(parsed.flags);

  try {
    writeAutomationConfig(cwd, config);
  } catch (error) {
    if (error instanceof z.ZodError) {
      structuredError({
        code: 'schema_violation',
        message: error.issues
          .map((issue) => {
            const pathString =
              issue.path.length === 0 ? '<root>' : issue.path.join('.');

            return `${pathString}: ${issue.message}`;
          })
          .join('; '),
        subcommand: SUBCOMMAND,
      });

      return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
    }
    structuredError({
      code: 'configure_automation_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {
      pnpm_audit: parsed.flags.pnpmAudit,
      stale_branches: parsed.flags.staleBranches,
      update_deps: parsed.flags.updateDeps,
      wiki: parsed.flags.wiki,
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
