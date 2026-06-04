/**
 * Branch-state helpers for `gaia wiki sync land`.
 *
 * Every helper shells out via `child_process.spawnSync` so that the
 * vitest suite can mock the entire surface with a single `vi.mock`. The
 * `runner` parameter on each function is the indirection point; tests
 * inject a fake `spawnSync` that returns canned `SpawnSyncReturns`.
 *
 * Errors are surfaced two ways:
 *   - For predicate-shaped helpers (`isProtectedBranch`, `isWorkingTreeDirty`)
 *     a non-zero exit on the underlying git call throws an `Error` whose
 *     message includes the failing argv. The handler catches and maps to
 *     exit code 2.
 *   - For value-shaped helpers (`currentBranch`, `stagedAndUnstagedPaths`)
 *     the same convention applies.
 */
import {spawnSync, type SpawnSyncReturns} from 'node:child_process';

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
    const stderr = (result.stderr ?? '').trim();
    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return result.stdout ?? '';
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

export type WorkingTreeStatus = {
  hasNonWikiChanges: boolean;
  hasWikiChanges: boolean;
  paths: string[];
};

/**
 * Inspect the working tree (staged + unstaged + untracked) and classify
 * paths by whether they sit under `wiki/`.
 *
 * Uses `git status --porcelain=v1 -uall`. The first two columns are
 * status codes; column 3 onwards is the path. Renames emit `orig -> new`
 * we treat both halves as touched paths.
 */
export const inspectWorkingTree = (
  cwd: string,
  runner: CommandRunner = defaultRunner
): WorkingTreeStatus => {
  const args = ['status', '--porcelain=v1', '-uall'];
  const out = expectSuccess(runner('git', args, {cwd}), 'git', args);
  const paths: string[] = [];

  for (const rawLine of out.split('\n')) {
    const line = rawLine.replace(/\r$/u, '');

    if (line.length === 0) continue;
    // Porcelain v1: 2-char status, space, path. Account for renames.
    const payload = line.slice(3);
    const renameSplit = payload.indexOf(' -> ');

    if (renameSplit === -1) {
      paths.push(payload);
    } else {
      paths.push(payload.slice(0, renameSplit));
      paths.push(payload.slice(renameSplit + 4));
    }
  }

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
