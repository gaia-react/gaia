/**
 * `gaia packages`: commands over the package registry (`.gaia/packages.json`).
 * `sync-settings` generates each package's `.claude/settings.json`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runSyncSettings} from './sync-settings.js';

const HELP_TEXT = `Usage: gaia packages <subcommand> [args]

  sync-settings [--check] [--repo-root <path>]
                             Generate <package>/.claude/settings.json.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'sync-settings': runSyncSettings,
};

export const run = (argv: readonly string[]): number => {
  const subcommand = argv[0];

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }
  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    return handler(argv.slice(1));
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown packages subcommand: ${subcommand}`,
    subcommand: `packages ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
