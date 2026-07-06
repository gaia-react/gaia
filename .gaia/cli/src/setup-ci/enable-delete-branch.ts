/**
 * `gaia setup-ci enable-delete-branch --owner <o> --repo <r>` handler.
 *
 * Runs `gh api -X PATCH repos/<owner>/<repo> -f delete_branch_on_merge=true`.
 * The slash command has already verified admin permission via
 * `check-admin` before invoking this primitive.
 *
 * Output JSON:
 *   `{ "applied": true }` on success.
 *   `{ "applied": false, "error": "gh_api_error" }` on failure.
 *
 * The error code is a stable identifier, never raw `gh` stderr,
 * because the slash command echoes this JSON to operator surfaces
 * that could leak tokens or repository internals.
 *
 * Exits 0 on success, non-zero on failure (so callers can branch on
 * exit code AND inspect the JSON for the error code).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/gh.js';

const HELP_TEXT = `Usage: gaia setup-ci enable-delete-branch --owner <o> --repo <r>

  PATCH repos/<owner>/<repo> -f delete_branch_on_merge=true via gh.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  let owner: string | undefined;
  let repo: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--owner') {
      owner = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--repo') {
      repo = argv[index + 1];
      index += 1;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'setup-ci enable-delete-branch',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (owner === undefined || repo === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'enable-delete-branch requires --owner <o> --repo <r>',
      subcommand: 'setup-ci enable-delete-branch',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = await runGh({
    args: [
      'api',
      '-X',
      'PATCH',
      `repos/${owner}/${repo}`,
      '-f',
      'delete_branch_on_merge=true',
    ],
    cwd: options.cwd ?? process.cwd(),
  });

  if (!result.ok) {
    process.stdout.write(
      `${JSON.stringify({applied: false, error: 'gh_api_error'})}\n`
    );

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  process.stdout.write(`${JSON.stringify({applied: true})}\n`);

  return EXIT_CODES.OK;
};
