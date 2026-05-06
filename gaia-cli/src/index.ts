/**
 * gaia CLI entrypoint.
 *
 * Top-level subcommand router. Dispatches to per-domain handlers under
 * `./telemetry/` and `./mentorship/` (added by Phase 2/3 tasks of the
 * SPEC-001 telemetry-v1 plan).
 *
 * Both hooks (bash) and slash-command code (Node) invoke this entry
 * via `bin/gaia`. The router is implemented as an object map (the
 * project's `no-switch` rule rejects switch statements; an object map
 * is the canonical replacement for top-level CLI routing).
 */
/* eslint-disable unicorn/no-process-exit -- this IS a CLI binary */
import {EXIT_CODES} from './exit.js';
import {structuredError} from './stderr.js';

const HELP_TEXT = `Usage: gaia <subcommand> [args]

  telemetry emit <event_type> [--field value ...]
  telemetry compute-profile
  mentorship enable|disable|purge|status
  mentorship analytics enable|disable|dry-run
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

type SubcommandModule = {
  run: (args: string[]) => number | Promise<number | undefined> | undefined;
};

const dispatchSubcommand = async (
  modulePath: string,
  args: string[]
): Promise<number> => {
  let loaded: SubcommandModule;

  try {
    loaded = (await import(modulePath)) as SubcommandModule;
  } catch (error) {
    structuredError({
      code: 'subcommand_not_implemented',
      message: error instanceof Error ? error.message : String(error),
      module: modulePath,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
  const result = await loaded.run(args);

  return typeof result === 'number' ? result : EXIT_CODES.OK;
};

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND_MODULES: Readonly<Partial<Record<string, string>>> = {
  mentorship: './mentorship/index.js',
  telemetry: './telemetry/index.js',
};

const main = async (): Promise<number> => {
  // process.argv[2] is undefined when no subcommand is supplied. Node's
  // typings model argv as `string[]` (no `noUncheckedIndexedAccess`),
  // so we coerce through unknown to express the runtime reality.
  const subcommand = process.argv[2] as string | undefined;
  const rest = process.argv.slice(3);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    printHelp();

    return EXIT_CODES.OK;
  }

  const modulePath = SUBCOMMAND_MODULES[subcommand];

  if (modulePath !== undefined) {
    return dispatchSubcommand(modulePath, rest);
  }

  structuredError({code: 'unknown_subcommand', subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

try {
  const exitCode = await main();
  process.exit(exitCode);
} catch (error: unknown) {
  structuredError({
    code: 'cli_internal_error',
    message: error instanceof Error ? error.message : String(error),
  });
  process.exit(EXIT_CODES.UNKNOWN_SUBCOMMAND);
}
