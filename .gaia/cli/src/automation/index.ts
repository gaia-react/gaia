/**
 * `gaia automation` subcommand router.
 *
 * The slice-1 surface for GAIA CI's local-side primitives. Mirrors the
 * shape of `wiki/index.ts`: object-map dispatch (no `switch`), exported
 * `run` returns `Promise<number>`, structured error on unknown subcommand.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runClearOverage} from './clear-overage.js';
import {run as runCronDecide} from './cron-decide.js';
import {run as runInstallAuditWorkflow} from './install-audit-workflow.js';
import {run as runReadConfig} from './read-config.js';
import {run as runReadState} from './read-state.js';
import {run as runRecordOverage} from './record-overage.js';
import {run as runRecordRun} from './record-run.js';
import {run as runRenderWorkflows} from './render-workflows.js';

const HELP_TEXT = `Usage: gaia automation <subcommand> [args]

  read-config [--json]
  read-state <tool> [--json]
  cron-decide <tool> [--json]
  record-run <tool> --sha <sha> --trigger <cron|force|workflow_dispatch> --cost <dollars> [--at <iso>]
  record-overage <tool> --cost <dollars>
  clear-overage <tool>
  render-workflows --out-dir <path> [--tools <csv>] [--dry-run]
  install-audit-workflow --out-dir <path> [--dry-run]
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'clear-overage': runClearOverage,
  'cron-decide': runCronDecide,
  'install-audit-workflow': runInstallAuditWorkflow,
  'read-config': runReadConfig,
  'read-state': runReadState,
  'record-overage': runRecordOverage,
  'record-run': runRecordRun,
  'render-workflows': runRenderWorkflows,
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
    message: `unknown automation subcommand: ${subcommand}`,
    subcommand: `automation ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
