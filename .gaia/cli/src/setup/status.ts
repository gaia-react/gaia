/**
 * `gaia setup status [--json]` handler.
 *
 * Reports whether the per-machine setup recorded by `.gaia/local/setup-state.json`
 * is complete. The statusline indicator and `/setup-gaia` slash command both
 * read this output to decide whether the indicator should appear and what
 * remains to do.
 *
 * JSON shape (the canonical machine-readable contract):
 *
 *   {
 *     "complete": boolean,
 *     "started_at": string | null,
 *     "completed_at": string | null,
 *     "completed_steps": string[],
 *     "pending_steps": string[]
 *   }
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  isComplete,
  pendingSteps,
  readStateFile,
  resolveMainWorktreeRoot,
} from './util/state-file.js';
import type {SetupStep} from './util/state-file.js';

const HELP_TEXT = `Usage: gaia setup status [--json]

  Print the per-machine setup state. Without --json, prints a human-readable
  summary. With --json, prints a single JSON line consumed by tooling.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

type StatusOutput = {
  complete: boolean;
  completed_at: null | string;
  completed_steps: SetupStep[];
  pending_steps: SetupStep[];
  started_at: null | string;
};

const printHuman = (output: StatusOutput): void => {
  if (output.complete) {
    process.stdout.write(
      `Setup complete (started ${String(output.started_at)}, finished ${String(output.completed_at)}).\n`
    );

    return;
  }

  const lines = ['Setup is incomplete.'];

  if (output.started_at !== null) {
    lines.push(`  Started: ${output.started_at}`);
  }

  if (output.completed_steps.length > 0) {
    lines.push(`  Completed: ${output.completed_steps.join(', ')}`);
  }
  lines.push(
    `  Pending: ${output.pending_steps.join(', ')}`,
    '  Run /setup-gaia to finish.'
  );
  process.stdout.write(`${lines.join('\n')}\n`);
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
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup status',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  let repoRoot: string;

  try {
    repoRoot = resolveMainWorktreeRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup status must run inside a git repository',
      subcommand: 'setup status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let state;

  try {
    state = readStateFile(repoRoot);
  } catch (error) {
    structuredError({
      code: 'state_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'setup status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const output: StatusOutput = {
    complete: isComplete(state),
    completed_at: state?.completed_at ?? null,
    completed_steps: state?.completed_steps ?? [],
    pending_steps: pendingSteps(state),
    started_at: state?.started_at ?? null,
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
