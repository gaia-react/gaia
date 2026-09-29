/**
 * `gaia setup-ci enable-dependabot-security --owner <o> --repo <r>` handler.
 *
 * Alerts and security updates are two SEPARATE repository settings; a
 * `.github/dependabot.yml` config alone opens neither. Enables both via
 * `gh api`, then reads each back to confirm the enable actually took
 * (a 204 on the PUT doesn't guarantee the setting stuck). The caller has
 * already run `check-admin`; this primitive does not re-probe permission.
 *
 * Output JSON:
 *   `{ "alerts_enabled": true, "security_updates_enabled": true, "paused": <bool> }` on success.
 *   `{ "alerts_enabled": <bool|null>, "security_updates_enabled": <bool|null>, "error": "gh_api_error", "step": "<step>" }` on failure.
 *
 * The error code is a stable identifier, never raw `gh` stderr, because
 * the slash command echoes this JSON to operator surfaces that could leak
 * tokens or repository internals (same reason as enable-delete-branch).
 *
 * Exits 0 on success, non-zero on failure.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/gh.js';

const HELP_TEXT = `Usage: gaia setup-ci enable-dependabot-security --owner <o> --repo <r> [--json]

  Enable and verify Dependabot alerts + security updates via gh.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

type Step =
  | 'enable_alerts'
  | 'enable_security_updates'
  | 'verify_alerts'
  | 'verify_security_updates';

const fail = (
  step: Step,
  alertsEnabled: boolean | null,
  securityUpdatesEnabled: boolean | null
): number => {
  process.stdout.write(
    `${JSON.stringify({
      alerts_enabled: alertsEnabled,
      error: 'gh_api_error',
      security_updates_enabled: securityUpdatesEnabled,
      step,
    })}\n`
  );

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

type ParsedArgs =
  | {message: string; status: 'invalid'}
  | {owner: string; repo: string; status: 'ok'}
  | {status: 'help'}
  | {status: 'missing_required_arg'};

const parseArgs = (argv: readonly string[]): ParsedArgs => {
  let owner: string | undefined;
  let repo: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== undefined) {
      if (HELP_TOKENS.has(token)) return {status: 'help'};

      if (token === '--owner') {
        owner = argv[index + 1];
        index += 1;
      } else if (token === '--repo') {
        repo = argv[index + 1];
        index += 1;
      } else if (token !== '--json') {
        // '--json' is accepted for symmetry with the other setup-ci verbs;
        // this command's output is unconditionally JSON already. Any
        // other token is unrecognized.
        return {message: `unknown flag: ${token}`, status: 'invalid'};
      }
    }
  }

  if (owner === undefined || repo === undefined) {
    return {status: 'missing_required_arg'};
  }

  return {owner, repo, status: 'ok'};
};

/** Runs the four-step enable-then-verify sequence, stopping at the first failure. */
const enableAndVerify = async (
  owner: string,
  repo: string,
  cwd: string
): Promise<number> => {
  const enableAlerts = await runGh({
    args: ['api', '-X', 'PUT', `repos/${owner}/${repo}/vulnerability-alerts`],
    cwd,
  });

  if (!enableAlerts.ok) return fail('enable_alerts', null, null);

  const enableSecurityUpdates = await runGh({
    args: [
      'api',
      '-X',
      'PUT',
      `repos/${owner}/${repo}/automated-security-fixes`,
    ],
    cwd,
  });

  if (!enableSecurityUpdates.ok) {
    return fail('enable_security_updates', null, null);
  }

  const verifyAlerts = await runGh({
    args: ['api', `repos/${owner}/${repo}/vulnerability-alerts`],
    cwd,
  });

  if (!verifyAlerts.ok) return fail('verify_alerts', false, null);

  const verifySecurityUpdates = await runGh({
    args: ['api', `repos/${owner}/${repo}/automated-security-fixes`],
    cwd,
  });

  if (!verifySecurityUpdates.ok) {
    return fail('verify_security_updates', true, null);
  }

  let securityUpdatesPayload: {enabled?: unknown; paused?: unknown};

  try {
    securityUpdatesPayload = JSON.parse(verifySecurityUpdates.stdout) as {
      enabled?: unknown;
      paused?: unknown;
    };
  } catch {
    return fail('verify_security_updates', true, null);
  }

  if (securityUpdatesPayload.enabled !== true) {
    return fail('verify_security_updates', true, false);
  }

  process.stdout.write(
    `${JSON.stringify({
      alerts_enabled: true,
      paused: securityUpdatesPayload.paused === true,
      security_updates_enabled: true,
    })}\n`
  );

  return EXIT_CODES.OK;
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const parsed = parseArgs(argv);

  if (parsed.status === 'help') {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (parsed.status === 'invalid') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'setup-ci enable-dependabot-security',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.status === 'missing_required_arg') {
    structuredError({
      code: 'missing_required_arg',
      message: 'enable-dependabot-security requires --owner <o> --repo <r>',
      subcommand: 'setup-ci enable-dependabot-security',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return enableAndVerify(
    parsed.owner,
    parsed.repo,
    options.cwd ?? process.cwd()
  );
};
