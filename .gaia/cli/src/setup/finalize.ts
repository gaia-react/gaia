/**
 * `gaia setup finalize` handler.
 *
 * Stamps `.gaia/local/setup-state.json` with `completed_at = now`. The
 * statusline indicator hides once `completed_at` is set, so this is the
 * single canonical signal that the per-machine setup is done.
 *
 * Refuses if any required step is still pending, unless `--force` is
 * supplied (escape hatch for maintainers who initialized manually before
 * `/setup-gaia` existed).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  pendingSteps,
  readStateFile,
  resolveMainWorktreeRoot,
  writeStateFile,
} from './util/state-file.js';
import type {SetupState} from './util/state-file.js';

const HELP_TEXT = `Usage: gaia setup finalize [--force]

  Marks .gaia/local/setup-state.json as complete (sets completed_at).
  Refuses if any step is still pending unless --force is passed.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  /** Override "now" for deterministic tests. */
  now?: () => Date;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let force = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--force') {
      force = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup finalize',
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
      message: 'gaia setup finalize must run inside a git repository',
      subcommand: 'setup finalize',
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
      subcommand: 'setup finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  const isoNow = nowDate.toISOString();

  const pending = pendingSteps(state);

  if (pending.length > 0 && !force) {
    structuredError({
      code: 'setup_steps_pending',
      message: `cannot finalize: ${pending.length} step(s) pending`,
      pending,
      subcommand: 'setup finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const next: SetupState = state ?? {
    completed_at: null,
    completed_steps: [],
    started_at: isoNow,
    version: 1,
  };
  next.completed_at = isoNow;
  writeStateFile(repoRoot, next);

  process.stdout.write(
    `${JSON.stringify({
      code: 'setup_finalized',
      completed_at: isoNow,
      forced: force && pending.length > 0,
    })}\n`
  );

  return EXIT_CODES.OK;
};
