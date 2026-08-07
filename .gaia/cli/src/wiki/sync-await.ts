/**
 * `gaia wiki sync await` handler.
 *
 * The `/gaia-wiki` router's same-session counterpart to the session-start
 * janitor (`.claude/hooks/local-janitor.sh`). A wiki landing's in-CLI merge
 * wait (`sync land --branch-aware`, `chain finish`) is structurally shorter
 * than the gate it waits on, so most landings take the timeout branch and
 * defer local catch-up (return to base, delete the branch, prune) to the
 * janitor's next session. This verb makes the common case same-session: the
 * router calls it, unconditionally, after the landing stage, and it takes
 * another bounded slice.
 *
 * Self-discovering and taking no branch argument by design: it enumerates
 * `wiki-sync/*` branches itself rather than trusting a name parsed out of
 * prose, and it is invoked the same way whether or not a landing is even
 * outstanding. The nothing-pending path is a silent no-op, which is what
 * makes one unconditional call correct on the standalone sync path, the full
 * chain, an in-place landing, and a run that already cleaned up.
 *
 * Never fails: every situation this verb can observe (nothing pending,
 * merged, still pending, loop ceiling reached) exits 0. Pending and
 * exhausted are reports, not errors; the landing already succeeded and only
 * the local catch-up is outstanding, and the janitor covers it either way.
 */
import {existsSync, mkdirSync, readFileSync, unlinkSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {defaultBranch, defaultRunner} from './util/branch.js';
import type {CommandRunner} from './util/branch.js';
import {
  cleanupAfterMerge,
  commandSucceeded,
  mergePollAttempts,
  waitForMerge,
} from './util/land.js';

// One of two expressions of the frozen branch-shape contract; the janitor's
// shell glob (`.claude/hooks/local-janitor.sh`) is the other. They must not
// diverge (README.md, "Branch shape, one definition for both halves").
const WIKI_SYNC_BRANCH = /^wiki-sync\/\d{4}-\d{2}-\d{2}-[0-9a-f]{7,40}$/u;

const CEILING_ENV_VAR = 'GAIA_WIKI_AWAIT_CEILING_SECONDS';
const CEILING_DEFAULT_SECONDS = 660;
const CEILING_FLOOR_SECONDS = 60;

const HELP_TEXT = `Usage: gaia wiki sync await

  Self-discovering local catch-up for a merged wiki-sync branch: waits (up
  to a bounded ceiling) for its PR to merge, then returns to the base
  branch, deletes the local branch, and prunes. Silent no-op when no
  wiki-sync/* branch is pending. Takes no arguments.

  Environment:
    GAIA_WIKI_AWAIT_CEILING_SECONDS  wait ceiling in seconds (default 660,
                                      floor 60, 0 disables the await)

  Exit code:
    0  always; pending/exhausted are reports, not errors
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const STATE_DIR_SEGMENTS = ['.gaia', 'local', 'cache', 'shared'] as const;
const STATE_FILENAME = 'wiki-await.json';

// `SpawnSyncReturns.stdout` is typed as non-nullable `string`, but a spawn
// failure can genuinely leave it `null`/`undefined` at runtime despite the
// type declaration.
const safeOutput = (value: null | string | undefined): string => value ?? '';

/**
 * Non-numeric falls back to the default; a below-floor numeric override is
 * raised to the floor; `0` is special-cased BEFORE the clamp so the opt-out
 * is real. Mirrors the janitor's shipped clamp idiom for
 * `GAIA_AUDIT_FINDINGS_RETENTION_HOURS` and `GAIA_CACHE_ARTIFACT_RETENTION_DAYS`
 * (`.claude/hooks/local-janitor.sh`).
 *
 * Trimmed once, up front, so a whitespace-padded override (`' 0 '`) is
 * recognized as the opt-out instead of falling through to `Number(' 0 ')`
 * and clamping up to the floor.
 */
const resolveCeilingSeconds = (raw: string | undefined): number => {
  const trimmed = raw?.trim();

  if (trimmed === '0') return 0;
  // `Number('')` (and whitespace-only) is `0`, which would otherwise slip
  // past the `Number.isInteger` / `< 0` checks below and clamp to the floor
  // instead of falling back to the default, same as any other non-numeric
  // override.
  if (trimmed === undefined || trimmed === '') return CEILING_DEFAULT_SECONDS;

  const parsed = Number(trimmed);

  if (!Number.isInteger(parsed) || parsed < 0) return CEILING_DEFAULT_SECONDS;

  return Math.max(parsed, CEILING_FLOOR_SECONDS);
};

/**
 * Enumerate local `wiki-sync/*` branches, validate each against the landing
 * branch shape before anything else touches it (AUDIT SEC-011), exclude the
 * current checkout (load-bearing: `cleanupAfterMerge` checks base out and
 * deletes the branch, and a stale reap-refused branch alongside a live chain
 * branch must never be selected over the branch actually in flight), then
 * take the most recent remaining match. Returns `undefined` when nothing
 * qualifies.
 *
 * Recency is git's own `--sort=-committerdate`, not the branch name: two
 * same-day branches carry a random short sha, so a lexicographic tie-break
 * on the name is arbitrary and can pick a stale reap-refused branch over the
 * one actually in flight. `for-each-ref` already returns candidates
 * most-recent-first, so the first remaining match after the exclusion is
 * the answer.
 */
const discoverBranch = (
  cwd: string,
  runner: CommandRunner
): string | undefined => {
  const listArgs = [
    'for-each-ref',
    '--sort=-committerdate',
    '--format=%(refname:short)',
    'refs/heads/wiki-sync/',
  ];
  const listResult = runner('git', listArgs, {cwd});

  if (!commandSucceeded(listResult)) return undefined;

  const candidates = safeOutput(listResult.stdout)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && WIKI_SYNC_BRANCH.test(line));

  if (candidates.length === 0) return undefined;

  const currentResult = runner(
    'git',
    ['symbolic-ref', '--quiet', '--short', 'HEAD'],
    {cwd}
  );
  const current =
    commandSucceeded(currentResult) ?
      safeOutput(currentResult.stdout).trim()
    : undefined;

  const remaining = candidates.filter((name) => name !== current);

  if (remaining.length === 0) return undefined;

  return remaining[0];
};

type PrLookup = 'closed' | 'merged' | 'open' | 'unknown';

// `gh`'s definitive "this PR does not exist for this branch" message. A
// branch that never got a PR (e.g. `sync land`'s remote sequence failed
// after the push, or the push itself failed) is a permanent state: no
// future poll will ever turn this into MERGED or OPEN, so it must not ride
// the same ceiling-bound wait as a transient failure.
const NO_PR_STDERR_PATTERN = /no pull requests found/iu;

/**
 * `gh pr view <branch>`: the same call `waitForMerge` polls with. A command
 * failure is either a real, permanent absence of a PR (gh's definitive "no
 * pull requests found" message) or a transient one (network/auth, or a `gh`
 * call that raced the PR's creation). Only the former is a real signal to
 * give up on; the latter must not be, because `waitForMerge` itself reads a
 * failing call as "not yet" and keeps polling, so a definitive give-up here
 * on a transient failure would contradict that reading of the identical
 * failure.
 */
const lookupPrState = (
  branch: string,
  cwd: string,
  runner: CommandRunner
): PrLookup => {
  const args = ['pr', 'view', branch, '--json', 'state', '--jq', '.state'];
  const result = runner('gh', args, {cwd});

  if (!commandSucceeded(result)) {
    const stderr = safeOutput(result.stderr).trim();

    // Definitive: this branch will never have a PR. Any other failure is
    // transient (network/auth/race) and must not be treated as a real
    // signal.
    return NO_PR_STDERR_PATTERN.test(stderr) ? 'closed' : 'unknown';
  }

  const state = safeOutput(result.stdout).trim();

  if (state === 'MERGED') return 'merged';
  if (state === 'OPEN') return 'open';

  return 'closed'; // a real CLOSED, or any other unexpected value
};

type AwaitState = {
  branch: string;
  started_at: number;
};

const stateFilePath = (repoRoot: string, stateDir: string | undefined) => {
  const dir = stateDir ?? path.join(repoRoot, ...STATE_DIR_SEGMENTS);

  return path.join(dir, STATE_FILENAME);
};

const readAwaitState = (filePath: string): AwaitState | null => {
  if (!existsSync(filePath)) return null;

  try {
    const parsed = JSON.parse(readFileSync(filePath, 'utf8')) as Partial<
      Record<keyof AwaitState, unknown>
    >;

    if (
      typeof parsed.branch !== 'string' ||
      typeof parsed.started_at !== 'number'
    )
      return null;

    return {branch: parsed.branch, started_at: parsed.started_at};
  } catch {
    return null; // absent, unreadable, or malformed: treat as "no prior state"
  }
};

const writeAwaitState = (filePath: string, state: AwaitState): void => {
  try {
    mkdirSync(path.dirname(filePath), {recursive: true});
    atomicWriteFileSync(filePath, `${JSON.stringify(state)}\n`);
  } catch {
    // Best-effort by design, like `readAwaitState`/`deleteAwaitState`: an
    // EACCES/EROFS/ENOSPC filesystem here must not escape `run` and break
    // its "never fails, exits 0" contract. Losing the durable ceiling just
    // means the next invocation restarts its own clock.
  }
};

const deleteAwaitState = (filePath: string): void => {
  try {
    unlinkSync(filePath);
  } catch {
    // Already absent, or unremovable; best-effort by design.
  }
};

const printMerged = (branch: string): void => {
  process.stdout.write(
    `sync-await: merged PR for ${branch} and cleaned up locally\n`
  );
  process.stdout.write('WIKI_AWAIT: merged\n');
};

const printPending = (branch: string): void => {
  process.stdout.write(
    `sync-await: merge still pending for ${branch}; the session-start janitor catches base up on a later session\n`
  );
  process.stdout.write('WIKI_AWAIT: pending\n');
};

const printExhausted = (branch: string): void => {
  process.stdout.write(
    `sync-await: await exhausted for ${branch}; the session-start janitor catches base up on a later session\n`
  );
  process.stdout.write('WIKI_AWAIT: exhausted\n');
};

const printMergedButNotOnBase = (branch: string): void => {
  process.stdout.write(
    `sync-await: merged PR for ${branch}, but HEAD is not on the base branch so local catch-up cannot run from here; the session-start janitor catches base up on a later session\n`
  );
  process.stdout.write('WIKI_AWAIT: exhausted\n');
};

type CleanUpAndReportMergedOptions = {
  branch: string;
  cwd: string;
  filePath: string;
  runner: CommandRunner;
};

/**
 * Gate the local catch-up on HEAD already sitting on base, the same
 * precondition the janitor's own fast-forward requires
 * (`.claude/hooks/local-janitor.sh` sweep #1d). `discoverBranch` only
 * excludes the branch HEAD is currently on, not every other branch, so a
 * merged-but-not-yet-reaped `wiki-sync/*` branch can be discovered while
 * HEAD sits on a third, unrelated branch. Switching the checkout in that
 * case would yank the caller's session onto base mid-workflow; skip the
 * catch-up instead and leave it to the janitor, which re-checks the same
 * gate on a later session.
 *
 * This is a stop, not a retry: HEAD does not move between invocations on
 * its own, so a `pending` marker here would tell the router to call this
 * verb again forever with byte-identical input and output (the merge
 * already landed; only local catch-up is outstanding, and this process has
 * no way to discharge it). The frozen marker table has exactly four
 * outcomes, so this reuses `exhausted`, whose router action is already
 * "stop" and whose documented meaning, "the session-start janitor takes the
 * catch-up on a later session", is exactly true here, with its own summary
 * line so the reason is not misreported as a ceiling that was never
 * reached.
 */
const cleanUpAndReportMerged = (
  options: CleanUpAndReportMergedOptions
): number => {
  const {branch, cwd, filePath, runner} = options;
  const base = defaultBranch(cwd, runner);
  const headResult = runner(
    'git',
    ['symbolic-ref', '--quiet', '--short', 'HEAD'],
    {cwd}
  );
  const head =
    commandSucceeded(headResult) ?
      safeOutput(headResult.stdout).trim()
    : undefined;

  if (head !== base) {
    deleteAwaitState(filePath);
    printMergedButNotOnBase(branch);

    return EXIT_CODES.OK;
  }

  cleanupAfterMerge({base, branch, cwd, runner});
  deleteAwaitState(filePath);
  printMerged(branch);

  return EXIT_CODES.OK;
};

export type RunOptions = {
  cwd?: string;
  now?: () => number;
  runner?: CommandRunner;
  sleep?: (ms: number) => void;
  stateDir?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  // No branch argument otherwise: self-discovery is the only source of the
  // branch name, so any other positional token is ignored rather than
  // risking a ref parsed out of prose reaching a destructive git call.
  const ceilingSeconds = resolveCeilingSeconds(process.env[CEILING_ENV_VAR]);

  if (ceilingSeconds === 0) return EXIT_CODES.OK; // opt-out: silent no-op

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const now = options.now ?? Date.now;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(cwd);
  } catch {
    // Never a failed landing; this verb never fails.
    return EXIT_CODES.OK;
  }

  const filePath = stateFilePath(repoRoot, options.stateDir);
  const branch = discoverBranch(repoRoot, runner);

  if (branch === undefined) {
    deleteAwaitState(filePath);

    return EXIT_CODES.OK;
  }

  const prior = readAwaitState(filePath);
  const priorStartedAt =
    prior !== null && prior.branch === branch ? prior.started_at : undefined;

  const lookup = lookupPrState(branch, repoRoot, runner);

  if (lookup === 'closed') {
    deleteAwaitState(filePath);

    return EXIT_CODES.OK;
  }

  if (lookup === 'merged') {
    return cleanUpAndReportMerged({branch, cwd: repoRoot, filePath, runner});
  }

  // lookup === 'open' or 'unknown': the durable ceiling lives in state
  // because each invocation is a separate process. Reset when the branch
  // changes (a mismatched prior state is treated as no prior state). An
  // 'unknown' lookup rides the same bounded ceiling across invocations as
  // 'open' rather than giving up immediately, per the comment on
  // `lookupPrState`.
  const startedAt = priorStartedAt ?? now();

  if (priorStartedAt === undefined) {
    writeAwaitState(filePath, {branch, started_at: startedAt});
  }

  if (now() - startedAt >= ceilingSeconds * 1000) {
    deleteAwaitState(filePath);
    printExhausted(branch);

    return EXIT_CODES.OK;
  }

  // An 'unknown' lookup already spent its one `gh` call above (inside
  // `lookupPrState`); it must not also spend `waitForMerge`'s own bounded
  // poll (up to `mergePollAttempts()` further calls, minutes of blocking
  // sleep) on a transient failure that has not even confirmed a PR exists
  // yet. It still reports pending and still accrues toward the ceiling on
  // the NEXT invocation, so it stays bounded without costing a full slice.
  if (lookup === 'unknown') {
    printPending(branch);

    return EXIT_CODES.OK;
  }

  const merged = waitForMerge({
    attempts: mergePollAttempts(),
    branch,
    cwd: repoRoot,
    runner,
    sleep: options.sleep,
  });

  if (merged) {
    return cleanUpAndReportMerged({branch, cwd: repoRoot, filePath, runner});
  }

  printPending(branch);

  return EXIT_CODES.OK;
};
