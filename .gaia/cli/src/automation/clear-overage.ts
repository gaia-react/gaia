/**
 * `gaia automation clear-overage <tool>` handler.
 *
 * Human-intervention escape hatch (per SPEC: "until a human clears it").
 * Sets `cost_overage = false` while preserving all other fields. State-
 * missing is a hard error; clearing on a never-run tool is a workflow
 * bug. Clearing when overage is already false is a silent OK.
 */
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import {readAutomationState} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeStateFile} from './util/state-write.js';

const HELP_TEXT = `Usage: gaia automation clear-overage <tool>

  Sets cost_overage = false on the per-tool state file. No-op when
  cost_overage is already false. Refuses if the state file is missing.
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

  for (const token of argv) {
    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation clear-overage',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!TOOL_ID_SET.has(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation clear-overage',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation clear-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'clear-overage requires <tool>',
      subcommand: 'automation clear-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation clear-overage must run inside a git repository',
      subcommand: 'automation clear-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationState(repoRoot, tool);

  if (result.status === 'missing') {
    structuredError({
      code: 'state_missing',
      message: `cannot clear overage: state file for "${tool}" does not exist`,
      subcommand: 'automation clear-overage',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'state_malformed',
      message: result.error,
      subcommand: 'automation clear-overage',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (!result.state.cost_overage) {
    return EXIT_CODES.OK;
  }

  writeStateFile(repoRoot, tool, {
    ...result.state,
    cost_overage: false,
  });

  return EXIT_CODES.OK;
};
