/**
 * `gaia scaffold` subcommand router (Phase 2 setup).
 *
 * This file ships:
 *   1. The public re-exports of the scaffold shared API.
 *   2. The router that dispatches to per-kind handlers.
 *
 * In this task, the four handlers (component/hook/route/service) are
 * stubbed to a "not yet implemented" stderr line + exit 1. The four
 * follow-up scaffolder tasks replace each stub with a real implementation
 * by editing this file.
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
export {ensureDir, writeFileIfAbsent} from './fs.js';
export {loadTemplate, renderTemplate} from './template.js';
export type {TemplateVars} from './template.js';
export type {ScaffoldResult} from './types.js';

const HELP_TEXT = `Usage: gaia scaffold <subcommand> [args]

  component <Name>         Scaffold a new React component (Phase 2).
  hook <useFoo>            Scaffold a new custom hook (Phase 2).
  route <name>             Scaffold a new route + page (Phase 2).
  service <name>           Scaffold a new API service (Phase 2).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const STUBBED_KINDS = new Set<string>();

const printNotImplemented = (kind: string): number => {
  structuredError({
    code: 'not_implemented',
    message: `scaffold ${kind}: not yet implemented (Phase 2)`,
    subcommand: `scaffold ${kind}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

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

  if (STUBBED_KINDS.has(subcommand)) {
    return printNotImplemented(subcommand);
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown scaffold subcommand: ${subcommand}`,
    subcommand: `scaffold ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
