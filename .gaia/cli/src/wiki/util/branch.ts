/**
 * Branch-state helpers for `gaia wiki sync land`.
 *
 * Every helper shells out via `child_process.spawnSync` so that the
 * vitest suite can mock the entire surface with a single `vi.mock`. The
 * `runner` parameter on each function is the indirection point; tests
 * inject a fake `spawnSync` that returns canned `SpawnSyncReturns`.
 *
 * Errors are surfaced one way: a helper whose answer depends on git
 * (`currentBranch`, `inspectWorkingTree`) throws an `Error` naming the failing
 * argv when that call fails or exits non-zero, and the handler catches it and
 * maps to exit code 2. Two helpers sit outside that convention on purpose:
 * `defaultBranch` falls back to `main` rather than throwing, since an unset
 * `origin/HEAD` is an ordinary state rather than a failure, and
 * `isProtectedBranch` runs no command at all.
 */
import {spawnSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {porcelainZPaths} from '../../util/git-status.js';

export type CommandRunner = (
  command: string,
  args: readonly string[],
  options: {cwd: string}
) => SpawnSyncReturns<string>;

export const defaultRunner: CommandRunner = (command, args, options) =>
  spawnSync(command, args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

const PROTECTED_BRANCHES = new Set(['main', 'master']);

// `SpawnSyncReturns.stdout`/`.stderr` are typed as non-nullable `string`, but
// a spawn failure can genuinely leave them `null`/`undefined` at runtime
// despite the type declaration. Routing through a parameter typed to include
// both keeps the `??` meaningful without an inline (and, at some call sites,
// "unnecessary") type assertion.
const safeOutput = (value: null | string | undefined): string => value ?? '';

const expectSuccess = (
  result: SpawnSyncReturns<string>,
  command: string,
  args: readonly string[]
): string => {
  if (result.error !== undefined) {
    throw new Error(
      `${command} ${args.join(' ')} failed: ${result.error.message}`
    );
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = safeOutput(result.stderr).trim();

    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return safeOutput(result.stdout);
};

/** Resolve the currently checked-out branch name. */
export const currentBranch = (
  cwd: string,
  runner: CommandRunner = defaultRunner
): string => {
  const args = ['rev-parse', '--abbrev-ref', 'HEAD'];
  const out = expectSuccess(runner('git', args, {cwd}), 'git', args);

  return out.trim();
};

/** Test whether `branch` is a protected branch (main / master). */
export const isProtectedBranch = (branch: string): boolean =>
  PROTECTED_BRANCHES.has(branch);

/**
 * Resolve the repository's default branch (the base a chain PR targets and
 * the branch `chain finish` returns to). Reads `origin/HEAD`; falls back to
 * `main` when the symbolic ref is unset (e.g. a freshly-cloned sandbox or a
 * repo whose remote HEAD was never resolved).
 */
export const defaultBranch = (
  cwd: string,
  runner: CommandRunner = defaultRunner
): string => {
  const args = ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'];
  const result = runner('git', args, {cwd});

  if (result.error !== undefined || (result.status ?? -1) !== 0) return 'main';

  const ref = safeOutput(result.stdout).trim();
  const stripped =
    ref.startsWith('origin/') ? ref.slice('origin/'.length) : ref;

  return stripped.length > 0 ? stripped : 'main';
};

export type WorkingTreeStatus = {
  hasNonWikiChanges: boolean;
  hasWikiChanges: boolean;
  paths: string[];
};

/**
 * Inspect the working tree (staged + unstaged + untracked) and classify
 * paths by whether they sit under `wiki/`.
 *
 * Uses `git status --porcelain=v1 -z -uall`, parsed by the shared
 * `porcelainZPaths`. `-uall` lists every untracked file rather than collapsing
 * a wholly-untracked directory to its name, so a new page under `wiki/` is
 * classified as itself. `-z` is what makes the classification trustworthy: a
 * quoted rename splits into a half that starts with `wiki/` and a half that
 * starts with `"`, which flips `hasNonWikiChanges` on a working tree holding
 * nothing but a wiki rename, and both callers gate on that flag.
 */
export const inspectWorkingTree = (
  cwd: string,
  runner: CommandRunner = defaultRunner
): WorkingTreeStatus => {
  const args = ['status', '--porcelain=v1', '-z', '-uall'];
  const paths = porcelainZPaths(
    expectSuccess(runner('git', args, {cwd}), 'git', args)
  );

  let hasWikiChanges = false;
  let hasNonWikiChanges = false;

  for (const candidate of paths) {
    if (candidate.startsWith('wiki/')) {
      hasWikiChanges = true;
    } else {
      hasNonWikiChanges = true;
    }
  }

  return {hasNonWikiChanges, hasWikiChanges, paths};
};
