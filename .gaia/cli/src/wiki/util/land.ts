import {z} from 'zod';
/**
 * Shared landing primitives for the wiki `chain` command.
 *
 * They shell out through an injected `CommandRunner` and translate git/gh
 * outcomes into the CLI's exit-code contract: 0 (ok) / 1 (refusal) /
 * 2 (unexpected).
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../../exit.js';
import type {CommandRunner} from './branch.js';
import {invalidateStatuslineCache} from './statusline-cache.js';

/** Exit code for an unexpected git/gh process failure. */
export const UNEXPECTED_EXIT = 2;

/** UTC `YYYY-MM-DD`; the date component of a `wiki/sync-<date>-<sha>` branch. */
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

// `SpawnSyncReturns.stdout`/`.stderr` are typed as non-nullable `string`, but
// a spawn failure can genuinely leave them `null`/`undefined` at runtime
// despite the type declaration.
const safeOutput = (value: null | string | undefined): string => value ?? '';

export type PassthroughFailureOptions = {
  args: readonly string[];
  command: string;
  prefix: string;
  result: SpawnSyncReturns<string>;
};

/**
 * Surface a failing git/gh step (command + argv + its stderr) under `prefix`
 * and return exit code 2. The caller gets enough context to diagnose without
 * re-running; the CLI adds nothing beyond that.
 */
export const passthroughFailure = (
  options: PassthroughFailureOptions
): number => {
  const {args, command, prefix, result} = options;
  const stderr = safeOutput(result.stderr).trim();
  const errorPart =
    result.error === undefined ? '' : ` (${result.error.message})`;
  const status = result.status ?? -1;
  process.stderr.write(
    `${prefix}: ${command} ${args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) process.stderr.write(`${stderr}\n`);

  return UNEXPECTED_EXIT;
};

/** Total blocking sleep budget for one merge-wait slice. */
export const MERGE_WAIT_BUDGET_MS = 240_000;

/** Pause between merge-state polls. */
export const MERGE_POLL_INTERVAL_MS = 30_000;

/**
 * Attempts derived from the budget, never tuned beside it. The loop sleeps
 * only BETWEEN polls, so N attempts spend (N - 1) x interval sleeping.
 */
export const mergePollAttempts = (
  budgetMs: number = MERGE_WAIT_BUDGET_MS,
  intervalMs: number = MERGE_POLL_INTERVAL_MS
): number => Math.floor(budgetMs / intervalMs) + 1;

/** Assumed worst case for one `gh pr view` round trip. */
export const GH_CALL_CEILING_MS = 10_000;

/** Assumed worst case for the merged path's network pull + fetch. */
export const CLEANUP_CEILING_MS = 60_000;

/**
 * Pinned upper bound for the whole blocking path of one CLI invocation.
 * Strictly below the 600_000 ms timeout every call site passes.
 */
export const MAX_SLICE_MS = 540_000;

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
  branch: string;
  cwd: string;
  runner: CommandRunner;
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
export const waitForMerge = (options: MergeWaitOptions): boolean => {
  const {
    attempts = mergePollAttempts(),
    branch,
    cwd,
    runner,
    sleep = sleepSync,
  } = options;
  const args = ['pr', 'view', branch, '--json', 'state', '--jq', '.state'];

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const result = runner('gh', args, {cwd});

    if (
      commandSucceeded(result) &&
      safeOutput(result.stdout).trim() === 'MERGED'
    )
      return true;

    if (attempt < attempts - 1) sleep(MERGE_POLL_INTERVAL_MS);
  }

  return false;
};

export type CleanupAfterMergeOptions = {
  base: string;
  branch: string;
  cwd: string;
  runner: CommandRunner;
};

/**
 * Local cleanup after a confirmed merge: return to `base`, fast-forward it to
 * the just-merged commit, delete the local landing branch, and prune the
 * deleted remote ref. Best-effort by design: the merge already succeeded, so a
 * stale local checkout or an already-pruned ref must not surface as an error.
 *
 * Returns whether the branch delete itself succeeded. `refs/heads/*` is
 * shared across worktrees, so `branch -D` is refused when `branch` is
 * checked out in another worktree; callers that report a terminal "cleaned
 * up" state to something else (e.g. a router) must not do so on a refusal,
 * or that something else reads "deleted" for a branch git still has
 * checked out elsewhere.
 */
export const cleanupAfterMerge = (
  options: CleanupAfterMergeOptions
): boolean => {
  const {base, branch, cwd, runner} = options;

  // `checkout` treats a bare `--` as the revision/pathspec divider (it would
  // reinterpret `base` as a pathspec, not a ref), so only `--end-of-options`
  // closes the option-injection vector here. Both `base` checkouts in this
  // module (this one and `finalizeMerge`'s timeout-path checkout below) take
  // `base` from the same sources, so both need it. `git pull` offers no
  // working separator at all: it strips `--` and re-execs its internal `git
  // fetch` without it (confirmed via `GIT_TRACE=1`), so a flag-shaped `base`
  // still reaches fetch as an option; that call is left as-is. `branch -D`
  // accepts the plan's `--` form.
  runner('git', ['checkout', '--end-of-options', base], {cwd});
  runner('git', ['pull', '--ff-only', 'origin', base], {cwd});
  const deleteResult = runner('git', ['branch', '-D', '--', branch], {cwd});
  runner('git', ['fetch', '--prune', 'origin'], {cwd});

  return commandSucceeded(deleteResult);
};

export type OutOfScopeStampOptions = {
  branch: string;
  cwd: string;
  prefix: string;
  runner: CommandRunner;
};

/** Whether the landing PR is ready for review after the stamp step. */
export type OutOfScopeStampResult = 'flip-failed' | 'not-posted' | 'ready';

const OUT_OF_SCOPE_DESCRIPTION = 'skipped: out of scope';

const PullRequestRecordSchema = z.object({
  baseRefName: z.string().min(1),
  files: z.array(z.object({path: z.string()})),
  headRefOid: z.string().min(1),
});

type PullRequestRecordResult =
  {reason: string} | {record: z.infer<typeof PullRequestRecordSchema>};

const failureDetail = (result: SpawnSyncReturns<string>): string => {
  const stderr = safeOutput(result.stderr).trim();

  return stderr === '' ? `exit ${result.status ?? -1}` : stderr;
};

const readPullRequestRecord = (
  options: OutOfScopeStampOptions
): PullRequestRecordResult => {
  const {branch, cwd, runner} = options;
  const view = runner(
    'gh',
    ['pr', 'view', branch, '--json', 'files,headRefOid,baseRefName'],
    {cwd}
  );

  if (!commandSucceeded(view)) {
    return {reason: `could not read the pull request (${failureDetail(view)})`};
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(safeOutput(view.stdout));
  } catch {
    return {reason: 'the pull request record is not JSON'};
  }

  const record = PullRequestRecordSchema.safeParse(parsed);

  return record.success ?
      {record: record.data}
    : {reason: 'the pull request record is malformed'};
};

/**
 * Post the `GAIA-Audit` out-of-scope success status on the landing branch's
 * head, for the wiki-only PR the CLI merges itself with auto-merge, outside the
 * Claude Code merge hook that stamps every other bypass PR, then mark the draft
 * PR ready for review. Call it after `gh pr create --draft` and before the
 * auto-merge step.
 *
 * The subject is the pull request, not the local checkout: both landers cut
 * their branch from a local default branch that can carry commits origin never
 * received, and a diff against it would hide those commits from the roster
 * while the PR still contains them. So the changed set is the PR's own file
 * list, its recorded head must be the commit this checkout holds, and the
 * roster is resolved against the PR base fetched from the remote.
 *
 * Refuses (one stderr line, no POST) unless every PR path is under `wiki/`, the
 * recorded head equals local `HEAD`, and the Code Audit Team roster dispatches
 * no member for the diff. The roster check keeps a later roster entry that owns
 * a `wiki/` path from letting the path check alone clear an in-scope PR. Any
 * failure to answer refuses too, since "could not answer" is not "nobody is
 * owed".
 *
 * The ready flip runs strictly after the status POST, so a reviewer is notified
 * only once the status exists. The result tells the caller whether the pull
 * request is now ready: `not-posted` leaves it a draft for the PR Merge
 * Workflow to flip, and `flip-failed` leaves a posted status on a still-draft
 * PR. Each prints its own next step, and the status is never rolled back.
 */
export const postOutOfScopeStamp = (
  options: OutOfScopeStampOptions
): OutOfScopeStampResult => {
  const {branch, cwd, prefix, runner} = options;

  const refusePost = (reason: string): OutOfScopeStampResult => {
    process.stderr.write(
      `${prefix}: GAIA-Audit out-of-scope stamp not posted: ${reason}; run the PR Merge Workflow on this pull request\n`
    );

    return 'not-posted';
  };

  const read = readPullRequestRecord(options);

  if ('reason' in read) {
    return refusePost(read.reason);
  }

  const {record} = read;

  const head = runner('git', ['rev-parse', 'HEAD'], {cwd});
  const headSha = commandSucceeded(head) ? safeOutput(head.stdout).trim() : '';

  if (headSha === '') {
    return refusePost('could not resolve the head commit');
  }

  if (record.headRefOid !== headSha) {
    return refusePost(
      'the pull request head is not the commit this checkout holds'
    );
  }

  if (
    record.files.length === 0 ||
    record.files.some((file) => !file.path.startsWith('wiki/'))
  ) {
    return refusePost('the pull request changes paths outside wiki/');
  }

  // A base name that starts with `-` would be read as an option by `git fetch`.
  if (record.baseRefName.startsWith('-')) {
    return refusePost('the pull request base name is not a branch name');
  }

  const fetchBase = runner('git', ['fetch', 'origin', record.baseRefName], {
    cwd,
  });

  if (!commandSucceeded(fetchBase)) {
    return refusePost(
      `could not fetch origin/${record.baseRefName} (${failureDetail(fetchBase)})`
    );
  }

  const members = runner(
    'bash',
    [
      '.gaia/scripts/resolve-audit-members.sh',
      '--root',
      cwd,
      '--base',
      `origin/${record.baseRefName}`,
    ],
    {cwd}
  );

  if (!commandSucceeded(members)) {
    return refusePost(
      `resolve-audit-members.sh could not answer (${failureDetail(members)})`
    );
  }

  const dispatched = safeOutput(members.stdout)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  if (dispatched.length > 0) {
    return refusePost(
      `the Code Audit Team dispatches ${dispatched.join(', ')} for this diff`
    );
  }

  const post = runner(
    'gh',
    [
      'api',
      '-X',
      'POST',
      `repos/{owner}/{repo}/statuses/${headSha}`,
      '-f',
      'state=success',
      '-f',
      'context=GAIA-Audit',
      '-f',
      `description=${OUT_OF_SCOPE_DESCRIPTION}`,
    ],
    {cwd}
  );

  if (!commandSucceeded(post)) {
    return refusePost(`the status POST failed (${failureDetail(post)})`);
  }

  const ready = runner('gh', ['pr', 'ready', branch], {cwd});

  if (!commandSucceeded(ready)) {
    process.stderr.write(
      `${prefix}: GAIA-Audit status posted but the draft flip failed (${failureDetail(ready)}); run: gh pr ready ${branch}\n`
    );

    return 'flip-failed';
  }

  return 'ready';
};

export type FinalizeMergeOptions = MergeWaitOptions & {
  base: string;
  prefix: string;
};

/**
 * Finish a protected-branch landing like any other PR: take one bounded wait
 * on the auto-merge, then either clean up locally (on `MERGED`) or return to
 * `base` and leave the local catch-up to the session-start janitor (on
 * timeout). Writes a one-line
 * `prefix`-tagged summary and returns `EXIT_CODES.OK`. Used by `chain finish`.
 */
export const finalizeMerge = (options: FinalizeMergeOptions): number => {
  const {base, branch, cwd, prefix, runner} = options;

  if (waitForMerge(options)) {
    cleanupAfterMerge({base, branch, cwd, runner});
    invalidateStatuslineCache(cwd);
    process.stdout.write(
      `${prefix}: merged PR for ${branch} and cleaned up locally\n`
    );

    return EXIT_CODES.OK;
  }

  // The merge did not land within the wait (slow/pending checks, a stuck
  // queue). Auto-merge stays queued and GitHub completes it once checks pass;
  // return to base and leave the local catch-up to the session-start janitor,
  // which prune-fetches, reaps the merged-and-gone branch, and fast-forwards
  // base on a later session. It does not depend on this wait succeeding.
  runner('git', ['checkout', '--end-of-options', base], {cwd});
  // Still invalidate: the next refresher run recomputes, and the nudge clears
  // once the queued merge lands and the main checkout's state file advances.
  invalidateStatuslineCache(cwd);
  process.stdout.write(
    `${prefix}: opened PR for ${branch}; auto-merge queued but not yet merged, local cleanup deferred\n`
  );

  return EXIT_CODES.OK;
};
