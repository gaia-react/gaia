import path from 'node:path';
import {resolveMainWorktreeRoot} from '../setup/util/state-file.js';

export type StorageRoots = {
  projectIdPath: string;
};

type ResolveArgs = {
  /**
   * A directory inside the repository to resolve FROM — not the answer. Named
   * `repoRoot` because that is what every caller and the concurrency meter's
   * C3-05 fixture already pass; renaming it would have meant editing a frozen
   * meter fixture in the same change that turns it green, which is how a false
   * green survives its own review.
   */
  repoRoot: string;
};

/**
 * Resolve the storage paths that are canonical to the CLONE, from any
 * directory inside any worktree of it.
 *
 * `.project-id` is one identity per clone (state registry: `scope: main-only`)
 * and its value is `sha256(repoRootPath)`, so the path this returns decides the
 * id. Anything that answers with the *calling* tree's root — the worktree's own
 * root, or a subdirectory of the checkout — mints a second identity for one
 * clone, and adoption telemetry then counts one adopter as N.
 *
 * So `repoRoot` is an operand to resolve FROM, never the answer itself: the
 * main checkout is derived from it through the one TypeScript main-root
 * resolver.
 *
 * Throws when `git` is unavailable or the operand is not inside a repository,
 * inheriting `resolveMainWorktreeRoot`'s contract. It deliberately does NOT
 * fall back to the calling directory — a fallback is what mints the wrong
 * identity, which is the defect this resolution exists to close. Callers that
 * can proceed without an id catch the throw and omit it (see `ping/send.ts`).
 */
export const resolveStorageRoots = ({repoRoot}: ResolveArgs): StorageRoots => {
  const mainRoot = resolveMainWorktreeRoot(repoRoot);
  const projectIdPath = path.join(mainRoot, '.gaia', 'local', '.project-id');

  return {
    projectIdPath,
  };
};
