/**
 * `gaia setup-ci dismiss-personal` handler.
 *
 * Writes `.gaia/local/automation.json` with `nudge_dismissed: true`.
 * The file is gitignored — this is the per-machine "stop nudging me"
 * record. Idempotent: re-running on an already-dismissed local writes
 * the same shape; the result is unchanged.
 *
 * If the existing local file is malformed, the handler refuses with
 * `local_malformed` rather than overwriting (slice 1's read helper
 * detects malformed shapes).
 */
import {EXIT_CODES} from '../exit.js';
import {readLocalAutomation} from '../schemas/local-automation.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeLocalAutomation} from './util/local-automation-write.js';

const HELP_TEXT = `Usage: gaia setup-ci dismiss-personal

  Write nudge_dismissed=true to .gaia/local/automation.json (gitignored).
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
      subcommand: 'setup-ci dismiss-personal',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup-ci dismiss-personal must run inside a git repository',
      subcommand: 'setup-ci dismiss-personal',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const existing = readLocalAutomation(repoRoot);

  if (existing.status === 'malformed') {
    structuredError({
      code: 'local_malformed',
      message: existing.error,
      subcommand: 'setup-ci dismiss-personal',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  // Read-then-merge: preserve any future fields slice 1's schema may
  // grow without a slice-4 update. The only field this primitive sets
  // is `nudge_dismissed`.
  const merged =
    existing.status === 'ok' ?
      {...existing.local, nudge_dismissed: true}
    : {nudge_dismissed: true, version: 1 as const};

  writeLocalAutomation(repoRoot, merged);

  process.stdout.write(`${JSON.stringify({dismissed: true})}\n`);

  return EXIT_CODES.OK;
};
