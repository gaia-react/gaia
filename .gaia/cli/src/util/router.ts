import {realpathSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from './argv.js';

/** A subcommand entry point; a missing result counts as success. */
export type SubcommandHandler = (
  args: string[]
) => number | Promise<number | undefined> | undefined;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * Builds a top-level `run(argv)` over a handler map. The helper imports no
 * handler itself, so each binary's bundle keeps only the handlers it passes in.
 */
export const createSubcommandRouter =
  (options: {
    handlers: Readonly<Partial<Record<string, SubcommandHandler>>>;
    helpText: string;
  }): ((argv: readonly string[]) => Promise<number>) =>
  async (argv) => {
    const subcommand = argv[0];
    const rest = argv.slice(1);

    if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
      process.stdout.write(options.helpText);

      return EXIT_CODES.OK;
    }

    const handler = lookupOwn(options.handlers, subcommand);

    if (handler !== undefined) {
      const result = await handler(rest);

      return typeof result === 'number' ? result : EXIT_CODES.OK;
    }

    structuredError({code: 'unknown_subcommand', subcommand});

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  };

/**
 * Runs `run` over `process.argv` only when the calling module is the invoked
 * file, and reports through `process.exitCode`.
 */
export const runWhenInvokedDirectly = async (
  importMetaUrl: string,
  run: (argv: readonly string[]) => Promise<number>
): Promise<void> => {
  // Auto-execute only when invoked directly as the bundled binary, not when a
  // test imports the entry module. Both binaries are invoked by explicit path
  // (`node .gaia/cli/gaia ...`), so argv[1] is the entry file; a test runner's
  // argv[1] is vitest, so the guard is false and no process.exit fires.
  const invokedPath = process.argv[1];
  const isDirectRun =
    invokedPath !== undefined &&
    importMetaUrl === pathToFileURL(realpathSync(invokedPath)).href;

  if (!isDirectRun) {
    return;
  }

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
};
