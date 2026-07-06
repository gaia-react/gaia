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

const printOutput = (output: CheckAdminOutput, json: boolean): void => {
  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }
};

// Extracted out of `run` (kept its cognitive complexity under the frozen
// limit): the two-step gh probe, independent of --json/human printing.
const probeAdmin = async (
  owner: string,
  repo: string,
  cwd: string
): Promise<CheckAdminOutput> => {
  // Step 1: gh auth status.
  const authResult = await runGh({args: ['auth', 'status'], cwd});

  if (!authResult.ok) {
    return {admin: false, auth_status: 'unauthenticated'};
  }

  // Step 2: gh api repos/<owner>/<repo> --jq .permissions.admin.
  const apiResult = await runGh({
    args: ['api', `repos/${owner}/${repo}`, '--jq', '.permissions.admin'],
    cwd,
  });

  if (!apiResult.ok) {
    return {
      admin: false,
      auth_status: 'api_error',
      error: apiResult.stderr.trim(),
    };
  }

  const trimmed = apiResult.stdout.trim();

  return {admin: trimmed === 'true', auth_status: 'ok'};
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
    } else if (token === '--owner') {
      owner = argv[index + 1];
      index += 1;
    } else if (token === '--repo') {
      repo = argv[index + 1];
      index += 1;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup-ci check-admin',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  if (owner === undefined || repo === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'check-admin requires --owner <o> --repo <r>',
      subcommand: 'setup-ci check-admin',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const output = await probeAdmin(owner, repo, options.cwd ?? process.cwd());

  printOutput(output, json);

  return EXIT_CODES.OK;
};
