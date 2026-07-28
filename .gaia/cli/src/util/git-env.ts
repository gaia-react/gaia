/**
 * Run `git` with `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_COMMON_DIR` stripped
 * from the child environment.
 *
 * TypeScript counterpart of `_gaia_git` in `.gaia/scripts/main-root-lib.sh`.
 * Those three, when set by a caller (a git hook, a `git rebase -x` step),
 * override repository discovery for every git subprocess regardless of
 * `-C`/`cwd`. An unstripped call would let an ambient override stand in for
 * the checkout's own on-disk layout, so every git-shelling resolver in this
 * tree routes through here rather than `execFileSync('git', ...)` directly.
 */
import {execFileSync} from 'node:child_process';

export const execGaiaGit = (args: string[], cwd: string): string => {
  const env = {...process.env};
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  delete env.GIT_COMMON_DIR;

  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env,
    // Node's 1 MiB default throws ENOBUFS on a large-output git command
    // (`git log` over a long history). Matches `runGit` in wiki/util/git.ts,
    // whose callers already hit that ceiling. Today's callers here are
    // short-output `rev-parse` forms, but the docblock above declares this
    // the one chokepoint every git-shelling resolver routes through, so the
    // ceiling belongs here rather than at the next caller to need it.
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
};
