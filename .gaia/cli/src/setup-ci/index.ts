/**
 * The `gaia setup-ci` namespace: the remote-integration and repository-policy
 * primitives `/setup-gaia` shells out to (remote detection, admin probe,
 * branch and Dependabot settings, project policy writers).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runCheckAdmin} from './check-admin.js';
import {run as runDetectRemote} from './detect-remote.js';
import {run as runEnableDeleteBranch} from './enable-delete-branch.js';
import {run as runEnableDependabotSecurity} from './enable-dependabot-security.js';
import {run as runWarnExistingTools} from './warn-existing-tools.js';
import {run as runWriteDependabotConfig} from './write-dependabot-config.js';
import {run as runWriteDependabotPolicy} from './write-dependabot-policy.js';
import {run as runWriteIsolationPolicy} from './write-isolation-policy.js';

const HELP_TEXT = `Usage: gaia setup-ci <subcommand> [args]

  detect-remote [--json]                   Read git remote get-url origin.
  warn-existing-tools [--json]             Detect Dependabot / Renovate configs.
  check-admin --owner <o> --repo <r> [--json]
                                           Probe repo admin permission via gh.
  enable-delete-branch --owner <o> --repo <r>
                                           PATCH delete_branch_on_merge=true.
  write-isolation-policy <policy>          Set the team's git isolation policy in .gaia/project.json.
  write-dependabot-config [--json]         Render or merge the npm security-updates entry into .github/dependabot.yml.
  write-dependabot-policy <on|off>         Record the Dependabot security-updates opt-in in .gaia/project.json.
  enable-dependabot-security --owner <o> --repo <r> [--json]
                                           Enable and verify Dependabot alerts + security updates via gh.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'check-admin': runCheckAdmin,
  'detect-remote': runDetectRemote,
  'enable-delete-branch': runEnableDeleteBranch,
  'enable-dependabot-security': runEnableDependabotSecurity,
  'warn-existing-tools': runWarnExistingTools,
  'write-dependabot-config': runWriteDependabotConfig,
  'write-dependabot-policy': runWriteDependabotPolicy,
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
    message: `unknown setup-ci subcommand: ${subcommand}`,
    subcommand: `setup-ci ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
