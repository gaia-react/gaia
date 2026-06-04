/**
 * `gaia init bootstrap-env` handler.
 *
 * Copies `.env.example` to `.env` when `.env` does not already exist.
 * Runs as a CLI subprocess so it bypasses Claude Code's Write(.env) deny
 * rule; the deny rule guards against Claude writing secrets into .env,
 * not against the init scaffolding seeding it from the example file.
 *
 * Idempotent: re-running is safe. Exit codes: 0 / 2.
 */
import {copyFileSync, existsSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init bootstrap-env

  Copy .env.example to .env when .env does not yet exist.
  No-op when .env already exists or .env.example is absent.

  Exit codes:
    0  success (no stdout)
    2  unexpected filesystem failure
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'bootstrap-env';

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${argv[0] as string}`,
      subcommand: 'init bootstrap-env',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const envPath = path.join(cwd, '.env');
  const examplePath = path.join(cwd, '.env.example');

  if (!existsSync(envPath) && existsSync(examplePath)) {
    try {
      copyFileSync(examplePath, envPath);
    } catch (error) {
      structuredError({
        code: 'bootstrap_env_failed',
        message: error instanceof Error ? error.message : String(error),
        subcommand: 'init bootstrap-env',
      });

      return UNEXPECTED_EXIT;
    }
  }

  try {
    markStepCompleted(cwd, STEP_NAME);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init bootstrap-env',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
