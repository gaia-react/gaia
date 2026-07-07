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
  --stale-branches <ci|local|off> \
  [--sandbox-recommended <true|false>]

  Write .gaia/automation.json with the user's tool-mode selections and
  setup_complete: false. Phase A of GAIA CI; no GitHub repo or workflow
  YAML required.

  Required flags:
    --wiki <ci|local|off>
    --update-deps <ci|local|off>
    --pnpm-audit <ci|local|off>
    --stale-branches <ci|local|off>

  Optional flags:
    --sandbox-recommended <true|false>
      Records the owner's Bash-sandbox recommendation. Omitted entirely
      when the flag is absent (no recommendation on file).

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
  sandboxRecommended?: boolean;
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
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as `string`,
  // not `string | undefined`; check the bound explicitly instead of
  // comparing the indexed value to `undefined`.
  if (index >= argv.length) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

const takeMode = (
  argv: readonly string[],
  index: number,
  context: {current: ToolMode | undefined; flag: string}
): {message: string; ok: false} | {mode: ToolMode; ok: true} => {
  const {current, flag} = context;

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

// The four tool-mode flags, required on every call. `sandboxRecommended` is
// optional and parsed separately below (its value domain is true/false, not
// ci/local/off, so it does not fit the `takeMode` shape).
type RequiredFlagKey = 'pnpmAudit' | 'staleBranches' | 'updateDeps' | 'wiki';

// Object lookup instead of an if/else-if chain per flag: every flag follows
// the identical take-mode-and-assign shape, so dispatching through a table
// keeps `parseFlags` itself flat (a Map, since a plain object's index
// signature would hide the genuine "unknown token" miss from TypeScript).
const FLAG_SPECS = new Map<string, {flag: string; key: RequiredFlagKey}>([
  ['--pnpm-audit', {flag: '--pnpm-audit', key: 'pnpmAudit'}],
  ['--stale-branches', {flag: '--stale-branches', key: 'staleBranches'}],
  ['--update-deps', {flag: '--update-deps', key: 'updateDeps'}],
  ['--wiki', {flag: '--wiki', key: 'wiki'}],
]);

const REQUIRED_MESSAGE: Readonly<Record<RequiredFlagKey, string>> = {
  pnpmAudit: '--pnpm-audit is required',
  staleBranches: '--stale-branches is required',
  updateDeps: '--update-deps is required',
  wiki: '--wiki is required',
};

const SANDBOX_RECOMMENDED_FLAG = '--sandbox-recommended';

const isBooleanLiteral = (value: string): value is 'false' | 'true' =>
  value === 'true' || value === 'false';

const takeSandboxRecommended = (
  argv: readonly string[],
  index: number,
  current: boolean | undefined
): {message: string; ok: false} | {ok: true; value: boolean} => {
  if (current !== undefined) {
    return {
      message: `${SANDBOX_RECOMMENDED_FLAG} specified twice`,
      ok: false,
    };
  }

  const taken = takeValue(argv, index, SANDBOX_RECOMMENDED_FLAG);

  if (!taken.ok) return taken;

  if (!isBooleanLiteral(taken.value)) {
    return {
      message: `${SANDBOX_RECOMMENDED_FLAG} must be one of: true, false`,
      ok: false,
    };
  }

  return {ok: true, value: taken.value === 'true'};
};

const applyToolFlag = (
  argv: readonly string[],
  index: number,
  context: {flags: Partial<Flags>; token: string}
): {message: string; ok: false} | {ok: true} => {
  const {flags, token} = context;
  const spec = FLAG_SPECS.get(token);

  if (spec === undefined) {
    return {message: `unknown flag: ${token}`, ok: false};
  }

  const taken = takeMode(argv, index, {
    current: flags[spec.key],
    flag: spec.flag,
  });

  if (!taken.ok) return taken;
  flags[spec.key] = taken.mode;

  return {ok: true};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  const flags: Partial<Flags> = {};
  let sandboxRecommended: boolean | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === SANDBOX_RECOMMENDED_FLAG) {
      const taken = takeSandboxRecommended(argv, index + 1, sandboxRecommended);

      if (!taken.ok) return taken;
      sandboxRecommended = taken.value;
    } else {
      const applied = applyToolFlag(argv, index + 1, {flags, token});

      if (!applied.ok) return applied;
    }

    index += 1;
  }

  for (const key of FLAG_SPECS.values()) {
    if (flags[key.key] === undefined) {
      return {message: REQUIRED_MESSAGE[key.key], ok: false};
    }
  }

  return {
    flags: {
      pnpmAudit: flags.pnpmAudit,
      sandboxRecommended,
      staleBranches: flags.staleBranches,
      updateDeps: flags.updateDeps,
      wiki: flags.wiki,
    } as Flags,
    ok: true,
  };
};

const buildConfig = (flags: Flags): AutomationConfig => ({
  pnpm_audit: {mode: flags.pnpmAudit, schedule: 'daily'},
  // Omit the key entirely when the flag was never passed (no recommendation
  // on file), rather than writing an explicit `undefined`.
  ...(flags.sandboxRecommended === undefined ?
    {}
  : {sandbox_recommended: flags.sandboxRecommended}),
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
