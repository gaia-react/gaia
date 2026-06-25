/**
 * `gaia react-perf` subcommand router.
 *
 * The deterministic Reduce layer of the `/gaia-react-perf` render-performance
 * diagnostic. Currently dispatches a single subcommand, `reduce`, which turns
 * a raw bippy render dump into a small ranked summary the skill consumes.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules,
 * mirroring `wiki/index.ts`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runReduce} from './reduce.js';

const HELP_TEXT = `Usage: gaia react-perf <subcommand> [args]

  reduce <raw.json> [--frame-budget-ms <n>]   Reduce a raw bippy render dump to
                                              a small ranked summary (JSON on
                                              stdout; default budget 16ms).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  reduce: runReduce,
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
    message: `unknown react-perf subcommand: ${subcommand}`,
    subcommand: `react-perf ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
