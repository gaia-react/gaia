/**
 * `gaia setup` subcommand router.
 *
 * Per-machine clone setup. The `/setup-gaia` slash command orchestrates
 * the externally-shelled installs (React Doctor, Playwright CLI, Serena
 * MCP, plugins, spec-kit) and calls these CLI primitives to record
 * progress in `.gaia/local/setup-state.json`.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runFinalize} from './finalize.js';
import {run as runMarkStep} from './mark-step.js';
import {run as runStatus} from './status.js';

const HELP_TEXT = `Usage: gaia setup <subcommand> [args]

  status [--json]            Print whether per-machine setup is complete.
  mark-step <step>           Record a setup step as complete.
  finalize [--force]         Mark setup as complete (refuses if steps pending).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  finalize: runFinalize,
  'mark-step': runMarkStep,
  status: runStatus,
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
    message: `unknown setup subcommand: ${subcommand}`,
    subcommand: `setup ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
