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

const STATE_DIR_SEGMENTS = ['.gaia', 'local', 'cache', 'shared'] as const;
const STATE_FILENAME = 'wiki-await.json';

// `SpawnSyncReturns.stdout` is typed as non-nullable `string`, but a spawn
// failure can genuinely leave it `null`/`undefined` at runtime despite the
// type declaration.
const safeOutput = (value: null | string | undefined): string => value ?? '';

/**
 * Non-numeric falls back to the default; a below-floor numeric override is
 * raised to the floor; `0` is special-cased BEFORE the clamp so the opt-out
 * is real. Mirrors the janitor's shipped clamp idiom
 * (`.claude/hooks/local-janitor.sh:619-621`, `:777-779`).
 */
const resolveCeilingSeconds = (raw: string | undefined): number => {
  if (raw === '0') return 0;
  if (raw === undefined) return CEILING_DEFAULT_SECONDS;

  const parsed = Number(raw);

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
 */
const discoverBranch = (
  cwd: string,
  runner: CommandRunner
): string | undefined => {
  const listArgs = [
    'for-each-ref',
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

  // The date-and-sha shape sorts lexicographically by date; ascending sort,
  // take the last (most recent).
  return remaining.toSorted((a, b) => a.localeCompare(b)).at(-1);
};

type PrLookup = 'closed' | 'merged' | 'open';

/** `gh pr view <branch>`: the same call `waitForMerge` polls with. */
const lookupPrState = (
  branch: string,
  cwd: string,
  runner: CommandRunner
): PrLookup => {
  const args = ['pr', 'view', branch, '--json', 'state', '--jq', '.state'];
  const result = runner('gh', args, {cwd});

  if (!commandSucceeded(result)) return 'closed'; // command failed / no PR found

  const state = safeOutput(result.stdout).trim();

  if (state === 'MERGED') return 'merged';
  if (state === 'OPEN') return 'open';

  return 'closed'; // CLOSED, or any other unexpected value
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
  mkdirSync(path.dirname(filePath), {recursive: true});
  atomicWriteFileSync(filePath, `${JSON.stringify(state)}\n`);
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

type CleanUpAndReportMergedOptions = {
  branch: string;
  cwd: string;
  filePath: string;
  runner: CommandRunner;
};

const cleanUpAndReportMerged = (
  options: CleanUpAndReportMergedOptions
): number => {
  const {branch, cwd, filePath, runner} = options;
  cleanupAfterMerge({base: defaultBranch(cwd, runner), branch, cwd, runner});
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
  _argv: readonly string[],
  options: RunOptions = {}
): number => {
  // No branch argument: self-discovery is the only source of the branch
  // name, so any positional token is ignored rather than risking a ref
  // parsed out of prose reaching a destructive git call.
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

  // lookup === 'open': the durable ceiling lives in state because each
  // invocation is a separate process. Reset when the branch changes (a
  // mismatched prior state is treated as no prior state).
  const startedAt = priorStartedAt ?? now();

  if (priorStartedAt === undefined) {
    writeAwaitState(filePath, {branch, started_at: startedAt});
  }

  if (now() - startedAt >= ceilingSeconds * 1000) {
    deleteAwaitState(filePath);
    printExhausted(branch);

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
