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

/**
 * The env-stripped call itself, returning git's output **verbatim**.
 *
 * Use this, not `execGaiaGit`, whenever the output's leading or trailing
 * whitespace carries meaning. `git status --porcelain` is the case that
 * matters: its records begin with a fixed two-column status field whose first
 * column is a SPACE for a worktree-only change (` M path`), so trimming the
 * payload shifts every column and a subsequent 3-character prefix slice eats
 * the path's own first character.
 */
export const execGaiaGitRaw = (args: string[], cwd: string): string => {
  const env = {...process.env};
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  delete env.GIT_COMMON_DIR;

  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env,
    // Node's 1 MiB default throws ENOBUFS on a large-output git command
    // (`git log` over a long history, `git status` on a very dirty tree).
    // Matches `runGit` in wiki/util/git.ts, whose callers already hit that
    // ceiling. The docblock above declares this the one chokepoint every
    // git-shelling resolver routes through, so the ceiling belongs here
    // rather than at the next caller to need it.
    maxBuffer: 64 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
};

/** `execGaiaGitRaw` trimmed, the right default for single-value forms. */
export const execGaiaGit = (args: string[], cwd: string): string =>
  execGaiaGitRaw(args, cwd).trim();
