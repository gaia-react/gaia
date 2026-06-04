/**
 * `gaia setup-ci status [--json]` handler.
 *
 * Reads `.gaia/automation.json` and `.gaia/local/automation.json` and
 * prints a Phase-B-readiness summary. The `/setup-gaia-ci` slash
 * command's first step is `status --json`; it bails when
 * `configured: false` (Phase A has not run).
 *
 * JSON shape (the canonical contract):
 *
 *   {
 *     "configured": boolean,
 *     "setup_complete": boolean,
 *     "setup_opted_out": boolean,
 *     "nudge_dismissed": boolean,
 *     "tools_enabled": ToolId[]
 *   }
 *
 * `tools_enabled` lists every tool whose `.mode == "ci"`. The handler
 * exits 0 in every branch; `status` is a query, not a gate.
 */
import {EXIT_CODES} from '../exit.js';
import {
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
  readAutomationConfig,
  type AutomationConfig,
  type ToolId,
} from '../schemas/automation-config.js';
import {readLocalAutomation} from '../schemas/local-automation.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia setup-ci status [--json]

  Print whether Phase B (GAIA CI remote integration) is configured.
  Exits 0 in every state; branch on the JSON output.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

type StatusOutput = {
  configured: boolean;
  nudge_dismissed: boolean;
  setup_complete: boolean;
  setup_opted_out: boolean;
  tools_enabled: ToolId[];
};

const enabledTools = (config: AutomationConfig): ToolId[] => {
  const result: ToolId[] = [];

  for (const tool of TOOL_IDS) {
    const key = TOOL_ID_TO_CONFIG_KEY[tool];
    const slot = config[key] as {mode: string} | undefined;

    if (slot !== undefined && slot.mode === 'ci') {
      result.push(tool);
    }
  }

  return result;
};

const printHuman = (output: StatusOutput): void => {
  if (!output.configured) {
    process.stdout.write(
      'GAIA CI is not configured for this repo. .gaia/automation.json is missing.\n'
    );

    return;
  }

  process.stdout.write(
    `configured: true\n` +
      `setup_complete: ${String(output.setup_complete)}\n` +
      `setup_opted_out: ${String(output.setup_opted_out)}\n` +
      `nudge_dismissed: ${String(output.nudge_dismissed)}\n` +
      `tools_enabled: ${output.tools_enabled.join(', ') || '(none)'}\n`
  );
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'setup-ci status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup-ci status must run inside a git repository',
      subcommand: 'setup-ci status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const configRead = readAutomationConfig(repoRoot);

  if (configRead.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: configRead.error,
      subcommand: 'setup-ci status',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const localRead = readLocalAutomation(repoRoot);

  if (localRead.status === 'malformed') {
    structuredError({
      code: 'local_malformed',
      message: localRead.error,
      subcommand: 'setup-ci status',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const output: StatusOutput =
    configRead.status === 'ok' ?
      {
        configured: true,
        nudge_dismissed:
          localRead.status === 'ok' ? localRead.local.nudge_dismissed : false,
        setup_complete: configRead.config.setup_complete,
        setup_opted_out: configRead.config.setup_opted_out,
        tools_enabled: enabledTools(configRead.config),
      }
    : {
        configured: false,
        nudge_dismissed:
          localRead.status === 'ok' ? localRead.local.nudge_dismissed : false,
        setup_complete: false,
        setup_opted_out: false,
        tools_enabled: [],
      };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
