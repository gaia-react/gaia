/**
 * `gaia setup-ci finalize` handler.
 *
 * Sets `setup_complete: true` in `.gaia/automation.json` via the
 * schema-typed write helper. The only primitive that flips
 * `setup_complete`. Idempotent; re-running on an already-finalized
 * config returns `already_finalized: true` without changing the
 * file's content (the write itself runs and is a no-op shape-wise).
 */
import {EXIT_CODES} from '../exit.js';
import {readAutomationConfig} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeAutomationConfig} from './util/automation-write.js';

const HELP_TEXT = `Usage: gaia setup-ci finalize

  Flip setup_complete=true in .gaia/automation.json. Idempotent.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'setup-ci finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup-ci finalize must run inside a git repository',
      subcommand: 'setup-ci finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationConfig(repoRoot);

  if (result.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: '.gaia/automation.json does not exist',
      subcommand: 'setup-ci finalize',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: result.error,
      subcommand: 'setup-ci finalize',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const alreadyFinalized = result.config.setup_complete;

  writeAutomationConfig(repoRoot, {
    ...result.config,
    setup_complete: true,
  });

  process.stdout.write(
    `${JSON.stringify({already_finalized: alreadyFinalized, finalized: true})}\n`
  );

  return EXIT_CODES.OK;
};
