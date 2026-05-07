/**
 * gaia CLI entrypoint.
 *
 * Top-level subcommand router. Dispatches to per-domain handlers under
 * `./telemetry/` and `./mentorship/`. The router is implemented as an
 * object map (the project's `no-switch` rule rejects switch statements;
 * an object map is the canonical replacement for top-level CLI routing).
 */
/* eslint-disable unicorn/no-process-exit -- this IS a CLI binary */
import {run as runFetchCoaching} from './adaptation/inject.js';
import {EXIT_CODES} from './exit.js';
import {run as runMentorship} from './mentorship/index.js';
import {run as runScaffold} from './scaffold/index.js';
import {structuredError} from './stderr.js';
import {run as runTelemetry} from './telemetry/index.js';
import {run as runUpdate} from './update/index.js';
import {run as runWiki} from './wiki/index.js';

const HELP_TEXT = `Usage: gaia <subcommand> [args]

  telemetry emit <event_type> [--field value ...]
  telemetry compute-profile
  mentorship enable|disable|purge|status
  mentorship analytics enable|disable|dry-run
  scaffold component|hook|route|service
  wiki state|commit-classify|state-bump|log-prepend|page-index|orphans|near-collisions
  update merge --baseline <dir> --latest <dir> --manifest <path>
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

type SubcommandHandler = (
  args: string[]
) => number | Promise<number | undefined> | undefined;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  mentorship: runMentorship,
  scaffold: runScaffold,
  telemetry: runTelemetry,
  update: runUpdate,
  wiki: runWiki,
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

  // Internal subcommand consumed by the `/gaia spec` skill (and future
  // dispatch-time callers) to fetch profile-driven coaching text. Wired
  // top-level rather than under `mentorship` because it's an
  // implementation detail consumed by skill scaffolding, not a
  // user-facing surface — kept out of the help text to match the
  // `mentorship _internal-*` precedent.
  if (subcommand === '_internal-fetch-coaching') {
    return runFetchCoaching(rest);
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({code: 'unknown_subcommand', subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

main()
  .then((exitCode) => {
    process.exit(exitCode);
  })
  .catch((error: unknown) => {
    structuredError({
      code: 'cli_internal_error',
      message: error instanceof Error ? error.message : String(error),
    });
    process.exit(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });
