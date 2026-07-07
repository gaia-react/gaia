/**
 * `gaia scaffold` subcommand router.
 *
 * This file ships:
 *   1. The public re-exports of the scaffold shared API.
 *   2. The router that dispatches to per-kind handlers
 *      (component/hook/route/service).
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runComponent} from './component.js';
import {run as runHook} from './hook.js';
import {run as runRoute} from './route.js';
import {run as runService} from './service.js';

export {insertIntoBarrel} from './barrel.js';

export {ensureDir} from './fs.js';

export {writeFileIfAbsent} from './fs.js';

export {loadTemplate} from './template.js';

export {renderTemplate} from './template.js';

export type {TemplateVars} from './template.js';

export type {ScaffoldResult} from './types.js';

const HELP_TEXT = `Usage: gaia scaffold <subcommand> [args]

  component <Name>         Scaffold a new React component.
  hook <useFoo>            Scaffold a new custom hook.
  route <name>             Scaffold a new route + page.
  service <name>           Scaffold a new API service.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * Entry point invoked by the top-level CLI router (`src/index.ts`).
 * Returns the process exit code; the top-level caller `process.exit`s.
 */
export const run = (argv: readonly string[]): number => {
  const subcommand = argv[0] as string | undefined;

  if (subcommand === undefined) {
    process.stderr.write(HELP_TEXT);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (subcommand === 'component') {
    return runComponent(argv.slice(1));
  }

  if (subcommand === 'hook') {
    return runHook(argv.slice(1));
  }

  if (subcommand === 'route') {
    return runRoute(argv.slice(1));
  }

  if (subcommand === 'service') {
    return runService(argv.slice(1));
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown scaffold subcommand: ${subcommand}`,
    subcommand: `scaffold ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
