/**
 * gaia-maintainer CLI entrypoint (maintainer-only binary).
 *
 * Release-only binary. Bundles to `.gaia/cli/gaia-maintainer`, which
 * `.gaia/release-exclude` strips from the adopter tarball. Adopters never
 * see this binary or any of its commands; only the GAIA template's own
 * maintainer (and CI jobs running on the maintainer's clone) invokes it.
 */

import {realpathSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {EXIT_CODES} from './exit.js';
import {run as runRelease} from './release/index.js';
import {structuredError} from './stderr.js';
import {lookupOwn} from './util/argv.js';

const HELP_TEXT = `Usage: gaia-maintainer <subcommand> [args]

Maintainer-only binary. Adopters use 'gaia' (no release namespace).

  release preflight|bump|changelog|scrub-wiki|manifest|scrub|runtime-deps|commit-and-tag|exclude-regex
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

type SubcommandHandler = (
  args: string[]
) => number | Promise<number | undefined> | undefined;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  release: runRelease,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    printHelp();

    return EXIT_CODES.OK;
  }

  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({code: 'unknown_subcommand', subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

// Auto-execute only when invoked directly as the bundled binary, not when a
// test imports this module. Both binaries are invoked by explicit path
// (`node .gaia/cli/gaia ...`), so argv[1] is this file; a test runner's
// argv[1] is vitest, so the guard is false and no process.exit fires.
const invokedPath = process.argv[1];
const isDirectRun =
  invokedPath !== undefined &&
  import.meta.url === pathToFileURL(realpathSync(invokedPath)).href;

if (isDirectRun) {
  // Set `process.exitCode` and let the event loop drain rather than calling
  // `process.exit()`. `process.stdout` is asynchronous when it is a pipe, so
  // an immediate `process.exit()` discards whatever is still buffered: a
  // `wiki commit-classify --json` over a non-trivial range truncated at
  // exactly 65536 bytes (the pipe capacity) and handed its caller unparseable
  // JSON, while the same command redirected to a file wrote all of it. The
  // sync playbook reads that command through a pipe.
  try {
    process.exitCode = await run(process.argv.slice(2));
  } catch (error: unknown) {
    structuredError({
      code: 'cli_internal_error',
      message: error instanceof Error ? error.message : String(error),
    });
    process.exitCode = EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
}
