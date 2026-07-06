/**
 * `gaia setup-ci check-admin --owner <o> --repo <r> [--json]` handler.
 *
 * Probes whether the authenticated user has admin permission on the
 * target repo. Returns a strict three-way `auth_status` enum so the
 * slash command can branch:
 *
 *   - `ok`              : gh auth + API both succeeded.
 *   - `unauthenticated` : gh auth status failed.
 *   - `api_error`       : auth ok but the repos API call failed.
 *
 * Contract: `admin: false` whenever `auth_status != "ok"`. Never
 * false-positive admin. Exits 0 in every branch; `check-admin` is a
 * query, not a gate.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/gh.js';

const HELP_TEXT = `Usage: gaia setup-ci check-admin --owner <o> --repo <r> [--json]

  Probe repo admin permission via \`gh\`. Returns admin: false for any
  non-ok auth status. Exits 0 in every branch.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type AuthStatus = 'api_error' | 'ok' | 'unauthenticated';

type CheckAdminOutput = {
  admin: boolean;
  auth_status: AuthStatus;
  error?: string;
};

type RunOptions = {
  cwd?: string;
};

const printHuman = (output: CheckAdminOutput): void => {
  process.stdout.write(
    `admin: ${String(output.admin)}\nauth_status: ${output.auth_status}\n`
  );
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  let json = false;
  let owner: string | undefined;
  let repo: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;

      continue;
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
      subcommand: 'setup-ci check-admin',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (owner === undefined || repo === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'check-admin requires --owner <o> --repo <r>',
      subcommand: 'setup-ci check-admin',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Step 1: gh auth status.
  const authResult = await runGh({
    args: ['auth', 'status'],
    cwd: options.cwd ?? process.cwd(),
  });

  if (!authResult.ok) {
    const output: CheckAdminOutput = {
      admin: false,
      auth_status: 'unauthenticated',
    };

    if (json) {
      process.stdout.write(`${JSON.stringify(output)}\n`);
    } else {
      printHuman(output);
    }

    return EXIT_CODES.OK;
  }

  // Step 2: gh api repos/<owner>/<repo> --jq .permissions.admin.
  const apiResult = await runGh({
    args: ['api', `repos/${owner}/${repo}`, '--jq', '.permissions.admin'],
    cwd: options.cwd ?? process.cwd(),
  });

  if (!apiResult.ok) {
    const output: CheckAdminOutput = {
      admin: false,
      auth_status: 'api_error',
      error: apiResult.stderr.trim(),
    };

    if (json) {
      process.stdout.write(`${JSON.stringify(output)}\n`);
    } else {
      printHuman(output);
    }

    return EXIT_CODES.OK;
  }

  const trimmed = apiResult.stdout.trim();
  const admin = trimmed === 'true';

  const output: CheckAdminOutput = {admin, auth_status: 'ok'};

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
