/**
 * The `gaia setup` namespace, the CLI primitives the `/setup-gaia` slash
 * command shells out to. It orchestrates the externally-shelled installs
 * (React Doctor, Playwright CLI, Serena MCP, plugins) and records per-machine
 * progress in `.gaia/local/setup-state.json` (`status`, `mark-step`,
 * `finalize`). The remote-integration and repository-policy verbs cover
 * remote detection, admin probe, branch setting, Dependabot alert settings and
 * the isolation policy writer.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runCheckAdmin} from './check-admin.js';
import {run as runConfigureDependabotAlerts} from './configure-dependabot-alerts.js';
import {run as runDetectRemote} from './detect-remote.js';
import {run as runEnableDeleteBranch} from './enable-delete-branch.js';
import {run as runFinalize} from './finalize.js';
import {run as runMarkStep} from './mark-step.js';
import {run as runStatus} from './status.js';
import {run as runWarnExistingTools} from './warn-existing-tools.js';
import {run as runWriteIsolationPolicy} from './write-isolation-policy.js';

const HELP_TEXT = `Usage: gaia setup <subcommand> [args]

  status [--json]            Print whether per-machine setup is complete.
  mark-step <step>           Record a setup step as complete.
  finalize [--force]         Mark setup as complete (refuses if steps pending).
  detect-remote [--json]                   Read git remote get-url origin.
  warn-existing-tools [--json]             Detect Dependabot / Renovate configs.
  check-admin --owner <o> --repo <r> [--json]
                                           Probe repo admin permission via gh.
  enable-delete-branch --owner <o> --repo <r>
                                           PATCH delete_branch_on_merge=true.
  write-isolation-policy <policy>          Set the team's git isolation policy in .gaia/project.json.
  configure-dependabot-alerts --owner <o> --repo <r> [--json]
                                           Turn Dependabot alerts on and automated security fixes off, then verify both, via gh.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'check-admin': runCheckAdmin,
  'configure-dependabot-alerts': runConfigureDependabotAlerts,
  'detect-remote': runDetectRemote,
  'enable-delete-branch': runEnableDeleteBranch,
  finalize: runFinalize,
  'mark-step': runMarkStep,
  status: runStatus,
  'warn-existing-tools': runWarnExistingTools,
  'write-isolation-policy': runWriteIsolationPolicy,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown setup subcommand: ${subcommand}`,
    subcommand: `setup ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
