/**
 * `gaia update` subcommand router.
 *
 * Phase 5 of the Claude Integration Optimization plan extracts the
 * `update-gaia` skill's prose Step 7 file walk into the CLI. The skill
 * itself still drives tarball fetching and user-facing prompts; this
 * router wires the deterministic byte-level merge under
 * `gaia update merge`.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runMerge} from './merge.js';

const HELP_TEXT = `Usage: gaia update <subcommand> [args]

  merge --baseline <dir> --latest <dir> --manifest <path> [--json]
                                              Three-way file compare per manifest class.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  merge: runMerge,
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
