/**
 * Shared landing primitives for the wiki `sync land` and `chain` commands.
 *
 * Both commands shell out through an injected `CommandRunner` and translate
 * git/gh outcomes into the CLI's exit-code contract: 0 (ok) / 1 (refusal) /
 * 2 (unexpected). These leaf helpers keep that translation identical across
 * the two surfaces.
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../../exit.js';
import type {CommandRunner} from './branch.js';

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
    result.error === undefined ? '' : ` (${result.error.message})`;
  const status = result.status ?? -1;
  process.stderr.write(
    `${prefix}: ${command} ${args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) process.stderr.write(`${stderr}\n`);

  return UNEXPECTED_EXIT;
};

/** Number of `gh pr view` polls before the merge wait gives up. */
const MERGE_POLL_ATTEMPTS = 10;

/** Pause between merge-state polls. */
const MERGE_POLL_INTERVAL_MS = 30_000;

/**
 * Block the current thread for `ms` without spinning, so the merge poll can
 * pause between `gh pr view` checks in an otherwise-synchronous CLI. Injectable
 * (see `MergeWaitOptions.sleep`) so tests never actually sleep.
 */
const sleepSync = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};

export type MergeWaitOptions = {
  attempts?: number;
  sleep?: (ms: number) => void;
};

/**
 * Poll `gh pr view <branch> --json state` until the PR reports `MERGED` or the
 * attempt budget runs out; returns `true` iff `MERGED` was observed. This is
 * the "wait for the gate to finish and turn green, then merge" half of landing
 * like any other PR: `--auto` queues the squash-merge server-side, GitHub
 * completes it once required checks pass, and this loop watches for that.
 *
 * The branch name (unique per run) selects the PR, so the poll works regardless
 * of which branch is currently checked out and still resolves the PR after
 * `--delete-branch` removes the head ref on merge. A failing `gh pr view`
 * (transient network / auth) counts as "not yet" and keeps polling rather than
 * aborting the wait.
 */
const waitForMerge = (
  runner: CommandRunner,
  cwd: string,
  branch: string,
  options: MergeWaitOptions
): boolean => {
  const attempts = options.attempts ?? MERGE_POLL_ATTEMPTS;
  const sleep = options.sleep ?? sleepSync;
  const args = ['pr', 'view', branch, '--json', 'state', '--jq', '.state'];

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const result = runner('gh', args, {cwd});

    if (commandSucceeded(result) && (result.stdout ?? '').trim() === 'MERGED')
      return true;

    if (attempt < attempts - 1) sleep(MERGE_POLL_INTERVAL_MS);
  }

  return false;
};

/**
 * Local cleanup after a confirmed merge: return to `base`, fast-forward it to
 * the just-merged commit, delete the local landing branch, and prune the
 * deleted remote ref. Best-effort by design: the merge already succeeded, so a
 * stale local checkout or an already-pruned ref must not surface as an error.
 */
const cleanupAfterMerge = (
  runner: CommandRunner,
  cwd: string,
  branch: string,
  base: string
): void => {
  runner('git', ['checkout', base], {cwd});
  runner('git', ['pull', '--ff-only', 'origin', base], {cwd});
  runner('git', ['branch', '-D', branch], {cwd});
  runner('git', ['fetch', '--prune', 'origin'], {cwd});
};

/**
 * Finish a protected-branch landing like any other PR: wait for the auto-merge
 * to land, then either clean up locally (on `MERGED`) or return to `base` and
 * defer cleanup to the session-start janitor (on timeout). Writes a one-line
 * `prefix`-tagged summary and returns `EXIT_CODES.OK`. Shared by `chain finish`
 * and `sync land`'s protected-branch path.
 */
export const finalizeMerge = (
  runner: CommandRunner,
  cwd: string,
  branch: string,
  base: string,
  prefix: string,
  options: MergeWaitOptions
): number => {
  if (waitForMerge(runner, cwd, branch, options)) {
    cleanupAfterMerge(runner, cwd, branch, base);
    process.stdout.write(
      `${prefix}: merged PR for ${branch} and cleaned up locally\n`
    );

    return EXIT_CODES.OK;
  }

  // The merge did not land within the wait (slow/pending checks, a stuck
  // queue). Auto-merge stays queued and GitHub completes it once checks pass;
  // return to base so the session-start janitor can prune the branch after the
  // merge (it never deletes the current branch), and defer the pull/delete to
  // that janitor.
  runner('git', ['checkout', base], {cwd});
  process.stdout.write(
    `${prefix}: opened PR for ${branch}; auto-merge queued but not yet merged, local cleanup deferred\n`
  );

  return EXIT_CODES.OK;
};
