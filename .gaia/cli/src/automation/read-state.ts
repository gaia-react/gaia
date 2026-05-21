/**
 * `gaia automation read-state <tool> [--json]` handler.
 *
 * Thin wrapper around `readAutomationState`. Exits non-zero with
 * `state_missing` when the state file does not exist — the CLI is a
 * primitive, not a fall-back-to-defaults abstraction. The workflow
 * uses `cron-decide` to handle first-run, not this command.
 */
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import {readAutomationState} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia automation read-state <tool> [--json]

  Reads .gaia/automation.state-<tool>.json and prints its content.
  <tool> must be one of: ${TOOL_IDS.join(', ')}.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const TOOL_ID_SET: ReadonlySet<string> = new Set(TOOL_IDS);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  let tool: ToolId | undefined;
  let json = false;

  for (const token of argv) {
    if (token === '--json') {
      json = true;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation read-state',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!TOOL_ID_SET.has(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token} (expected one of ${TOOL_IDS.join(', ')})`,
          subcommand: 'automation read-state',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation read-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'read-state requires a <tool> argument',
      subcommand: 'automation read-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation read-state must run inside a git repository',
      subcommand: 'automation read-state',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationState(repoRoot, tool);

  if (result.status === 'missing') {
    structuredError({
      code: 'state_missing',
      message: `.gaia/automation.state-${tool}.json does not exist`,
      subcommand: 'automation read-state',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'state_malformed',
      message: result.error,
      subcommand: 'automation read-state',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (json) {
    process.stdout.write(`${JSON.stringify(result.state)}\n`);
  } else {
    const s = result.state;
    process.stdout.write(
      `version: ${String(s.version)}\n` +
        `last_run_at: ${s.last_run_at}\n` +
        `last_run_sha: ${s.last_run_sha}\n` +
        `last_run_trigger: ${s.last_run_trigger}\n` +
        `skip_count: ${String(s.skip_count)}\n` +
        `last_run_cost: ${String(s.last_run_cost)}\n` +
        `cost_overage: ${String(s.cost_overage)}\n`
    );
  }

  return EXIT_CODES.OK;
};
