/**
 * `gaia setup-ci write-tool-mode <tool> <mode>` handler.
 *
 * Updates a single tool's `mode` field in `.gaia/automation.json`.
 * The per-tool state files are separate from the committed config: the
 * tool's `mode` lives in `.gaia/automation.json`, a different file with
 * a different schema. This primitive bridges that gap so the slash
 * command (and `--reconfigure` flow) can flip a tool's mode without
 * editing the config by hand.
 *
 * Refuses when the config is missing or malformed (fail-closed).
 *
 * Output JSON: `{ "tool": "<tool>", "mode": "<mode>" }`.
 */
import {EXIT_CODES} from '../exit.js';
import {
  readAutomationConfigRaw,
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
  ToolModeSchema,
} from '../schemas/automation-config.js';
import type {
  AutomationConfig,
  ToolId,
  ToolMode,
} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeAutomationConfig} from './util/automation-write.js';

const HELP_TEXT = `Usage: gaia setup-ci write-tool-mode <tool> <mode>

  Set a tool's mode in .gaia/automation.json.
  <tool> must be one of: ${TOOL_IDS.join(', ')}.
  <mode> must be one of: ci, local, off.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const toolToken = argv[0];
  const modeToken = argv[1] as string | undefined;
  const rest = argv.slice(2);

  if (rest.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${rest[0]}`,
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!(TOOL_IDS as readonly string[]).includes(toolToken)) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown tool: ${toolToken}. Supported: ${TOOL_IDS.join(', ')}`,
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (modeToken === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'write-tool-mode requires <mode>',
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const modeResult = ToolModeSchema.safeParse(modeToken);

  if (!modeResult.success) {
    structuredError({
      code: 'invalid_arguments',
      message: `invalid mode: ${modeToken}. Supported: ci, local, off`,
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const tool = toolToken as ToolId;
  const mode: ToolMode = modeResult.data;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup-ci write-tool-mode must run inside a git repository',
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationConfigRaw(repoRoot);

  if (result.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: '.gaia/automation.json does not exist',
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: result.error,
      subcommand: 'setup-ci write-tool-mode',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const key = TOOL_ID_TO_CONFIG_KEY[tool];
  // Spread the RAW slot (not the Zod-stripped `result.config[key]`) so an
  // unknown sub-field a newer binary wrote inside this slot survives the
  // round-trip; only `mode` is overridden. A raw slot with no `schedule`
  // spreads to no `schedule`; one with a `schedule` keeps it.
  const existingSlot = (result.raw[key] ?? {}) as Record<string, unknown>;

  writeAutomationConfig(repoRoot, {
    ...result.raw,
    [key]: {...existingSlot, mode},
  } as AutomationConfig);

  process.stdout.write(`${JSON.stringify({mode, tool})}\n`);

  return EXIT_CODES.OK;
};
