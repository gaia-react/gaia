/**
 * `gaia init finalize` handler.
 *
 * Codifies the cleanup that closes the final step of `/gaia-init`:
 * deletes `.claude/commands/gaia-init.md` so the command cannot be run a
 * second time.
 *
 * `pnpm install` is intentionally NOT performed here; it is a side
 * effect handled by the orchestrating skill before the CLI runs. The
 * anonymous adoption ping is likewise not sent here; the `/gaia-init`
 * Step 11 skill call sends it via `gaia ping --event init` (see
 * `../ping/index.ts`) after this handler returns.
 *
 * Idempotent: re-running is safe; an already-deleted command file stays
 * gone.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, rmSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init finalize

  Final cleanup steps for /gaia-init: delete the gaia-init.md command
  file so init cannot be run a second time.

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (unknown flag)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'finalize';

const INIT_COMMAND = '.claude/commands/gaia-init.md';

const removeIfPresent = (cwd: string, relative: string): void => {
  const absolute = path.join(cwd, relative);

  if (existsSync(absolute)) {
    rmSync(absolute, {force: true, recursive: true});
  }
};

type RunOptions = {
  cwd?: string;
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  // No flags; but reject any tokens to keep the surface small.
  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${argv[0] as string}`,
      subcommand: 'init finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  try {
    removeIfPresent(cwd, INIT_COMMAND);
  } catch (error) {
    structuredError({
      code: 'finalize_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init finalize',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init finalize',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
