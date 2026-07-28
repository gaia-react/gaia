/**
 * Resolve the calling git working tree's own root ("which tree am I in").
 *
 * This is the TypeScript counterpart of shell's `gaia_resolve_tree_root`
 * (`.gaia/scripts/main-root-lib.sh`): both answer "which tree is this",
 * for the main checkout and a linked worktree alike, from wherever the
 * caller happens to be running.
 *
 * It is NOT the main-checkout resolver. Anything deciding where SHARED
 * state lives must use `resolveMainWorktreeRoot`
 * (`.gaia/cli/src/util/main-root.ts`) instead, which answers
 * "where is main" regardless of which tree the caller is running from.
 */
import {execGaiaGit} from './git-env.js';

/** Resolve the repository root (`git rev-parse --show-toplevel`). */
export const resolveRepoRoot = (cwd: string = process.cwd()): string =>
  execGaiaGit(['rev-parse', '--show-toplevel'], cwd);
