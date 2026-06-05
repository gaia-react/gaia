/**
 * `gaia fitness` subcommand router.
 *
 * Presentation helpers for the /gaia-fitness health check. The skill runs the
 * checks inline (greps / `jq` / `gaia wiki ...`) and computes grades, then
 * pipes the assembled report JSON through `render-card` to produce the ASCII
 * report card it pastes into chat.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runRenderCard} from './render-card.js';

const HELP_TEXT = `Usage: gaia fitness <subcommand> [args]

  render-card [--cols N]    Render the /gaia-fitness report card from report
                            JSON on stdin (width-aware ASCII).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'render-card': runRenderCard,
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
    message: `unknown fitness subcommand: ${subcommand}`,
    subcommand: `fitness ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
