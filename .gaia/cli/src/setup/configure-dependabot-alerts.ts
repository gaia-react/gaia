/**
 * `gaia setup configure-dependabot-alerts --owner <o> --repo <r>` handler.
 *
 * Dependabot is a sensor only: alerts stay on, and automated security fixes
 * (the setting that opens security pull requests) stay off. Turns alerts on,
 * reads the automated-security-fixes setting and disables it only when it is
 * on, then reads both back to confirm the settings took (a 204 on a write
 * does not guarantee the setting stuck). The caller has already run
 * `check-admin`; this primitive does not re-probe permission.
 *
 * Output JSON:
 *   `{ "alerts_enabled": true, "automated_security_fixes_enabled": false, "changed": [...] }` on success.
 *   `{ "alerts_enabled": <bool|null>, "automated_security_fixes_enabled": <bool|null>, "changed": [...], "error": "gh_api_error", "step": "<step>", "manual_commands": [...] }` on failure.
 *
 * The error code is a stable identifier, never raw `gh` stderr, because
 * the slash command echoes this JSON to operator surfaces that could leak
 * tokens or repository internals (same reason as enable-delete-branch). An
 * organization-enforced security configuration that refuses the disable
 * lands here as `step: "disable_security_fixes"`.
 *
 * Exits 0 on success, non-zero on failure.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGhAsync} from '../util/run-process.js';

const SUBCOMMAND = 'setup configure-dependabot-alerts';

const HELP_TEXT = `Usage: gaia setup configure-dependabot-alerts --owner <o> --repo <r> [--json]

  Turn Dependabot alerts on and automated security fixes off, then verify both, via gh.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const FIXES_DISABLED_CHANGE = 'automated security fixes disabled';

type Repository = {owner: string; repo: string};

type RunOptions = {
  cwd?: string;
};

type SettingsState = {
  alertsEnabled: boolean | null;
  changed: string[];
  fixesEnabled: boolean | null;
};

type Step =
  | 'disable_security_fixes'
  | 'enable_alerts'
  | 'read_security_fixes'
  | 'verify_alerts'
  | 'verify_security_fixes';

const fail = (
  step: Step,
  state: SettingsState,
  {owner, repo}: Repository
): number => {
  process.stdout.write(
    `${JSON.stringify({
      alerts_enabled: state.alertsEnabled,
      automated_security_fixes_enabled: state.fixesEnabled,
      changed: state.changed,
      error: 'gh_api_error',
      manual_commands: [
        `gh api -X PUT repos/${owner}/${repo}/vulnerability-alerts`,
        `gh api -X DELETE repos/${owner}/${repo}/automated-security-fixes`,
      ],
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
        // '--json' is accepted for symmetry with the other setup verbs;
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

/** The `enabled` flag of an automated-security-fixes body, or null when the body is not that shape. */
const parseEnabled = (stdout: string): boolean | null => {
  try {
    const parsed = JSON.parse(stdout) as unknown;

    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      'enabled' in parsed &&
      typeof parsed.enabled === 'boolean'
    ) {
      return parsed.enabled;
    }
  } catch {
    return null;
  }

  return null;
};

/** Runs the five-step configure-then-verify sequence, stopping at the first failure. */
const configureAndVerify = async (
  owner: string,
  repo: string,
  cwd: string
): Promise<number> => {
  const target: Repository = {owner, repo};
  const state: SettingsState = {
    alertsEnabled: null,
    changed: [],
    fixesEnabled: null,
  };
  const alertsPath = `repos/${owner}/${repo}/vulnerability-alerts`;
  const fixesPath = `repos/${owner}/${repo}/automated-security-fixes`;

  const enableAlerts = await runGhAsync({
    args: ['api', '-X', 'PUT', alertsPath],
    cwd,
  });

  if (!enableAlerts.ok) return fail('enable_alerts', state, target);

  const readFixes = await runGhAsync({args: ['api', fixesPath], cwd});

  if (!readFixes.ok) return fail('read_security_fixes', state, target);

  const fixesBefore = parseEnabled(readFixes.stdout);

  if (fixesBefore === null) {
    return fail('read_security_fixes', state, target);
  }

  state.alertsEnabled = true;
  state.fixesEnabled = fixesBefore;

  if (fixesBefore) {
    const disableFixes = await runGhAsync({
      args: ['api', '-X', 'DELETE', fixesPath],
      cwd,
    });

    if (!disableFixes.ok) {
      return fail('disable_security_fixes', state, target);
    }

    state.changed.push(FIXES_DISABLED_CHANGE);
  }

  const verifyAlerts = await runGhAsync({args: ['api', alertsPath], cwd});

  if (!verifyAlerts.ok) {
    state.alertsEnabled = false;

    return fail('verify_alerts', state, target);
  }

  const verifyFixes = await runGhAsync({args: ['api', fixesPath], cwd});
  const fixesAfter = verifyFixes.ok ? parseEnabled(verifyFixes.stdout) : null;

  state.fixesEnabled = fixesAfter;

  if (fixesAfter !== false) {
    return fail('verify_security_fixes', state, target);
  }

  process.stdout.write(
    `${JSON.stringify({
      alerts_enabled: true,
      automated_security_fixes_enabled: false,
      changed: state.changed,
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
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.status === 'missing_required_arg') {
    structuredError({
      code: 'missing_required_arg',
      message: 'configure-dependabot-alerts requires --owner <o> --repo <r>',
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return configureAndVerify(
    parsed.owner,
    parsed.repo,
    options.cwd ?? process.cwd()
  );
};
