/**
 * `gaia update` subcommand router.
 *
 * Hosts the field-aware `merge-workspace` verdict oracle the
 * `/update-gaia` skill invokes for `pnpm-workspace.yaml` (Step 7b). The
 * skill hand-walks the per-file decision table (Step 7) and field-merges
 * `package.json` (Step 7a) itself, so the router carries no generic
 * whole-file merge command.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runMergeWorkspace} from './merge-workspace.js';

const HELP_TEXT = `Usage: gaia update <subcommand> [args]

  merge-workspace --baseline <file> --latest <file> --current <file> [--json]
                                              Field-aware pnpm-workspace.yaml verdict.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'merge-workspace': runMergeWorkspace,
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
    message: `unknown update subcommand: ${subcommand}`,
    subcommand: `update ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
