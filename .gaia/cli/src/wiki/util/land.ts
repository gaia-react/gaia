/**
 * Shared landing primitives for the wiki `sync land` and `chain` commands.
 *
 * Both commands shell out through an injected `CommandRunner` and translate
 * git/gh outcomes into the CLI's exit-code contract: 0 (ok) / 1 (refusal) /
 * 2 (unexpected). These leaf helpers keep that translation identical across
 * the two surfaces.
 */
import {type SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../../exit.js';

/** Exit code for an unexpected git/gh process failure. */
export const UNEXPECTED_EXIT = 2;

/** UTC `YYYY-MM-DD`; the date component of a `wiki-sync/<date>-<sha>` branch. */
export const todayUtc = (now: Date = new Date()): string => {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

/** Print a user-correctable refusal to stderr and return exit code 1. */
export const refuse = (message: string): number => {
  process.stderr.write(`${message}\n`);

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

/** A git/gh step succeeded: no spawn error and a zero exit status. */
export const commandSucceeded = (result: SpawnSyncReturns<string>): boolean =>
  result.error === undefined && (result.status ?? -1) === 0;

/**
 * Surface a failing git/gh step (command + argv + its stderr) under `prefix`
 * and return exit code 2. The caller gets enough context to diagnose without
 * re-running; the CLI adds nothing beyond that.
 */
export const passthroughFailure = (
  prefix: string,
  result: SpawnSyncReturns<string>,
  command: string,
  args: readonly string[]
): number => {
  const stderr = (result.stderr ?? '').trim();
  const errorPart =
    result.error !== undefined ? ` (${result.error.message})` : '';
  const status = result.status ?? -1;
  process.stderr.write(
    `${prefix}: ${command} ${args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) process.stderr.write(`${stderr}\n`);

  return UNEXPECTED_EXIT;
};
