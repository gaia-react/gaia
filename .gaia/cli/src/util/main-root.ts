/**
 * Resolve the MAIN checkout's root, regardless of which worktree the
 * caller is running from. Sibling to `repo-root.ts`'s `resolveRepoRoot`
 * (which answers "which tree is this"); this answers "where is main", the
 * anchor every clone-wide shared state file must resolve against.
 */
import {realpathSync} from 'node:fs';
import path from 'node:path';
import {execGaiaGit} from './git-env.js';

/**
 * `realpathSync`-canonicalized equality, used only to compare candidates
 * during validation, never to decide what `resolveMainWorktreeRoot`
 * returns. Two spellings of the same directory (a symlinked temp dir, a
 * relative vs. absolute path) must not read as a validation failure.
 */
const sameRealPath = (a: string, b: string): boolean => {
  try {
    return realpathSync(a) === realpathSync(b);
  } catch {
    return false;
  }
};

/**
 * Validate a resolved main-root candidate against the git-common-dir the
 * resolution started from, mirroring `_gaia_validate_main_root_candidate`
 * in `main-root-lib.sh`. One `git rev-parse --show-toplevel --git-common-dir`
 * call against the candidate returns both values, one per line in flag
 * order; a candidate that does not exist or is not a git working tree fails
 * that call outright and is rejected with the same message (a missing
 * directory cannot round-trip through `--show-toplevel` any more than a
 * non-repo directory can, so there is no separate wording for it). Accepts
 * only when the candidate's own `--show-toplevel` equals the candidate AND
 * the candidate's own `--git-common-dir` equals the common dir this
 * resolution started from. The second condition is what rejects an ambient
 * override and the "parent of a separate git dir sits inside an unrelated
 * repo" case: both would otherwise report SOME toplevel, but never one
 * whose own common dir loops back to where this resolution began. Throws,
 * naming the reason and the candidate, rather than returning an unvalidated
 * path.
 */
const validateMainRootCandidate = (
  candidate: string,
  expectedCommonDir: string
): void => {
  let toplevel: string;
  let commonDirRaw: string;

  try {
    const output = execGaiaGit(
      ['rev-parse', '--show-toplevel', '--git-common-dir'],
      candidate
    );
    // Split on CRLF as well as LF. execGaiaGit only trims the whole string,
    // so a CR on the first line would survive into `toplevel`, make
    // sameRealPath throw, and reject a valid main root with the misleading
    // "is not its own working-tree toplevel" error. This is the one
    // chokepoint both resolvers route through, so it absorbs the cost.
    [toplevel, commonDirRaw] = output.split(/\r?\n/);
  } catch {
    throw new Error(
      `resolveMainWorktreeRoot: candidate main root is not a git working tree: ${candidate}`
    );
  }

  if (!sameRealPath(toplevel, candidate)) {
    throw new Error(
      `resolveMainWorktreeRoot: candidate main root is not its own working-tree toplevel (git reports '${toplevel}'): ${candidate}`
    );
  }

  const commonDirAbs =
    path.isAbsolute(commonDirRaw) ? commonDirRaw : (
      path.resolve(candidate, commonDirRaw)
    );

  if (!sameRealPath(commonDirAbs, expectedCommonDir)) {
    throw new Error(
      `resolveMainWorktreeRoot: candidate main root's git-common-dir ('${commonDirAbs}') does not match the resolution's own common directory ('${expectedCommonDir}'): ${candidate}`
    );
  }
};

/**
 * Resolve the main worktree's root from any cwd inside any worktree of
 * the same repository.
 *
 * `git rev-parse --show-toplevel` returns the calling worktree's root,
 * which differs between the main checkout and a linked worktree. The
 * setup-state file is canonical to the clone (not per-worktree), so
 * every reader/writer must anchor to the SAME path regardless of which
 * worktree they ran from. `--git-common-dir` returns the shared `.git`
 * directory (the main repo's `.git` in every worktree); the directory
 * containing it is the main worktree root.
 *
 * Every git call here routes through `execGaiaGit`, which strips the three
 * repository-discovery env overrides (see its docblock). The candidate this
 * derives (`dirname(git-common-dir)`) is then validated by
 * `validateMainRootCandidate` before it is returned, so this function
 * throws rather than answering with a candidate it cannot corroborate
 * against git's own reported layout.
 *
 * The value this function RETURNS is the candidate exactly as computed,
 * never `realpath`'d. Validation canonicalizes both sides of each
 * comparison (see `sameRealPath`) so two spellings of one directory don't
 * cause a spurious failure, but that canonicalization is for the comparison
 * only: the string returned here is hashed into an adopter's project id
 * (`storage/project-id.ts`, via `storage/paths.ts`), so changing its
 * spelling would rotate every existing adopter's identity.
 *
 * Two divergences from this function's shell twin (`gaia_resolve_main_root`
 * in `main-root-lib.sh`) are deliberate, not gaps:
 *   - the shell twin physically resolves (`pwd -P`) the path it returns;
 *     this one does not, for the identity-stability reason above.
 *   - the shell twin reads `core.worktree` from the common dir's config for
 *     a linked worktree; this one does not, because that case is
 *     submodules, which GAIA does not support (see the assumption note
 *     below).
 *
 * Assumption: `--git-common-dir` returns the shared `.git` (relative
 * `.git` from main, or an absolute path like `/repo/.git` from a linked
 * worktree). `path.dirname` of that yields the main checkout root. This
 * holds for standard git worktrees but NOT submodules, where the common
 * dir is an internal gitdir path inside the parent repo. GAIA does not
 * support a submodule topology; do not change the resolution strategy
 * without re-validating that constraint.
 *
 * Throws if `git` is unavailable, `cwd` is not inside a git repo, or the
 * candidate fails validation; matching `resolveRepoRoot`'s contract so
 * callers can translate to the existing `not_a_git_repo` exit code.
 */
export const resolveMainWorktreeRoot = (cwd: string): string => {
  const commonDir = execGaiaGit(['rev-parse', '--git-common-dir'], cwd);

  const absoluteCommonDir =
    path.isAbsolute(commonDir) ? commonDir : path.resolve(cwd, commonDir);

  const candidate = path.dirname(absoluteCommonDir);

  validateMainRootCandidate(candidate, absoluteCommonDir);

  return candidate;
};
