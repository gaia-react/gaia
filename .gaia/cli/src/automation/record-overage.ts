/**
 * `gaia automation record-overage <tool> --cost <dollars>` handler.
 *
 * Post-run edit: only sets `cost_overage = true` and `last_run_cost`.
 * All other fields are preserved. Exits non-zero with `state_missing`
 * when the state file does not exist (calling record-overage without a
 * prior run is a workflow bug).
 */
import {EXIT_CODES} from '../exit.js';
import {TOOL_IDS, type ToolId} from '../schemas/automation-config.js';
import {readAutomationState} from '../schemas/automation-state.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeStateFile} from './util/state-write.js';

const HELP_TEXT = `Usage: gaia automation record-overage <tool> --cost <dollars>

  Marks the most recent run as a cost overage and records its actual cost.
  Refuses if the state file is missing (record-overage is a post-run edit).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

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
  let costStr: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--cost') {
      costStr = argv[index + 1];
      index += 1;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'automation record-overage',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (tool === undefined) {
      if (!(TOOL_IDS as readonly string[]).includes(token)) {
        structuredError({
          code: 'invalid_arguments',
          message: `unknown tool: ${token}`,
          subcommand: 'automation record-overage',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      tool = token as ToolId;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'automation record-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (tool === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'record-overage requires <tool>',
      subcommand: 'automation record-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (costStr === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'record-overage requires --cost <dollars>',
      subcommand: 'automation record-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cost = Number.parseFloat(costStr);

  if (!Number.isFinite(cost) || cost < 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `--cost must be a non-negative number; got: "${costStr}"`,
      subcommand: 'automation record-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia automation record-overage must run inside a git repository',
      subcommand: 'automation record-overage',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationState(repoRoot, tool);

  if (result.status === 'missing') {
    structuredError({
      code: 'state_missing',
      message: `cannot record overage: state file for "${tool}" does not exist`,
      subcommand: 'automation record-overage',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'state_malformed',
      message: result.error,
      subcommand: 'automation record-overage',
      tool,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  writeStateFile(repoRoot, tool, {
    ...result.state,
    cost_overage: true,
    last_run_cost: cost,
  });

  return EXIT_CODES.OK;
};
