/**
 * `gaia setup-ci` subcommand router.
 *
 * The Phase B remote-integration surface for GAIA CI. Every primitive
 * the `/setup-gaia-ci` slash command shells out to lives under this
 * namespace — remote detection, admin permission probe, token
 * piping (stdin only), workflow_dispatch verification, and the
 * `setup_complete` flip.
 *
 * Object-map dispatch (no `switch`) per the project's typescript
 * conventions; mirrors the shape of `setup/index.ts` and
 * `automation/index.ts`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runCheckAdmin} from './check-admin.js';
import {run as runDetectRemote} from './detect-remote.js';
import {run as runDismissPersonal} from './dismiss-personal.js';
import {run as runEnableDeleteBranch} from './enable-delete-branch.js';
import {run as runFinalize} from './finalize.js';
import {run as runOptOutTeam} from './opt-out-team.js';
import {run as runSetSecret} from './set-secret.js';
import {run as runStatus} from './status.js';
import {run as runVerifyRun} from './verify-run.js';
import {run as runWarnExistingTools} from './warn-existing-tools.js';

const HELP_TEXT = `Usage: gaia setup-ci <subcommand> [args]

  status [--json]                          Print Phase B configuration status.
  detect-remote [--json]                   Read git remote get-url origin.
  warn-existing-tools [--json]             Detect Dependabot / Renovate configs.
  check-admin --owner <o> --repo <r> [--json]
                                           Probe repo admin permission via gh.
  dismiss-personal                         Write nudge_dismissed=true (per-machine).
  opt-out-team                             Write setup_opted_out=true (committed).
  enable-delete-branch --owner <o> --repo <r>
                                           PATCH delete_branch_on_merge=true.
  set-secret <name>                        Pipe stdin into gh secret set <name>.
  verify-run <workflow-file> [--timeout-seconds N] [--json]
                                           Trigger workflow_dispatch and watch run.
  finalize                                 Flip setup_complete=true.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  'check-admin': runCheckAdmin,
  'detect-remote': runDetectRemote,
  'dismiss-personal': runDismissPersonal,
  'enable-delete-branch': runEnableDeleteBranch,
  finalize: runFinalize,
  'opt-out-team': runOptOutTeam,
  'set-secret': runSetSecret,
  status: runStatus,
  'verify-run': runVerifyRun,
  'warn-existing-tools': runWarnExistingTools,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

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
