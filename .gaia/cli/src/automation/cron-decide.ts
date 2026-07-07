/**
 * `gaia automation cron-decide <tool> [--json]` handler.
 *
 * The smart-cron decision primitive. Reads `.gaia/automation.json` and
 * returns a deterministic `{decision, reason, skip_log_line}` triple.
 * Pure config-only: it never reads or mutates any state file. An enabled
 * wiki tool runs; a non-wiki tool emits a not-yet-implemented placeholder
 * skip; a tool whose mode is `off` emits a tool_off skip.
 *
 * Exit code 0 covers both `run` and `skip` decisions. Non-zero covers
 * configuration errors (missing or malformed config).
 */
import {EXIT_CODES} from '../exit.js';
import {
  readAutomationConfig,
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
} from '../schemas/automation-config.js';
import type {
  AutomationConfig,
  ToolConfig,
  ToolId,
} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

type CronDecision = {
  decision: 'run' | 'skip';
  reason: CronReason;
  skip_log_line: null | string;
};

type CronReason = 'enabled' | 'tool_off';

const HELP_TEXT = `Usage: gaia automation cron-decide <tool> [--json]

  Smart-cron decision primitive. Reads .gaia/automation.json and emits
  {decision, reason, skip_log_line}.
  Decision priority:
    1. tool_off   (config.<tool>.mode == "off")
    2. enabled    (wiki, mode != off -> run)
  Non-wiki tools are not yet implemented and skip with a placeholder.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const TOOL_ID_SET: ReadonlySet<string> = new Set(TOOL_IDS);

const toolConfigFor = (config: AutomationConfig, tool: ToolId): ToolConfig =>
  // `TOOL_ID_TO_CONFIG_KEY` is typed `Record<ToolId, ToolConfigKey>`, so the
  // indexed access resolves directly to `ToolConfig`; no cast needed.
  config[TOOL_ID_TO_CONFIG_KEY[tool]];

type DecideArgs = {
  tool: ToolId;
  toolConfig: ToolConfig;
};

const decide = (args: DecideArgs): CronDecision => {
  const {tool, toolConfig} = args;

  // 1. tool_off
  if (toolConfig.mode === 'off') {
    return {
      decision: 'skip',
      reason: 'tool_off',
      skip_log_line: 'tool mode is off; skipping',
    };
  }

  // Non-wiki tools are not yet implemented. Emit a clearly-tagged
  // tool_off-shaped placeholder so the workflow can see the limitation
  // and bail.
  if (tool !== 'wiki') {
    return {
      decision: 'skip',
      reason: 'tool_off',
      skip_log_line: `cron-decide not yet implemented for ${tool}; skipping`,
    };
  }

  // 2. enabled: a configured wiki tool always runs.
  return {decision: 'run', reason: 'enabled', skip_log_line: null};
};

type ArgvParseResult =
  {exitCode: number; ok: false} | {json: boolean; ok: true; tool: ToolId};

const parseCronDecideArgs = (argv: readonly string[]): ArgvParseResult => {
  let tool: ToolId | undefined;
  let json = false;

  for (const token of argv) {
    if (token === '--json') {
      json = true;
    } else if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation cron-decide',
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND, ok: false};
    } else if (tool === undefined) {
      if (!TOOL_ID_SET.has(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation cron-decide',
        });

        return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND, ok: false};
      }
      tool = token as ToolId;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unexpected argument: ${token}`,
        subcommand: 'automation cron-decide',
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND, ok: false};
    }
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'cron-decide requires <tool>',
      subcommand: 'automation cron-decide',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND, ok: false};
  }

  return {json, ok: true, tool};
};

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

  const parsed = parseCronDecideArgs(argv);

  if (!parsed.ok) {
    return parsed.exitCode;
  }

  const {json, tool} = parsed;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation cron-decide must run inside a git repository',
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const configResult = readAutomationConfig(repoRoot);

  if (configResult.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message:
        'cron-decide requires .gaia/automation.json; running cron-decide on an unconfigured repo is a setup bug',
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (configResult.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: configResult.error,
      subcommand: 'automation cron-decide',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const toolConfig = toolConfigFor(configResult.config, tool);

  const decision = decide({tool, toolConfig});

  if (json) {
    process.stdout.write(`${JSON.stringify(decision)}\n`);
  } else {
    process.stdout.write(
      `decision: ${decision.decision}\n` +
        `reason: ${decision.reason}\n` +
        `skip_log_line: ${decision.skip_log_line ?? '(none)'}\n`
    );
  }

  return EXIT_CODES.OK;
};
