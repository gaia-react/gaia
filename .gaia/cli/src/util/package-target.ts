import path from 'node:path';
import {loadPackages} from './packages.js';
import {resolveRepoRoot} from './repo-root.js';

export type PackageTarget =
  | {message: string; ok: false}
  | {ok: true; packageDir: string; packagePath: string; repoRoot: string};

/**
 * The tree a CLI command acts on: the calling working tree's root, so a
 * command run from `frontend/` and from the repo root name the same tree.
 * Falls back to `cwd` when git cannot answer, because scaffolding must not
 * require a repository (an adopter may scaffold before `git init`).
 */
const resolveTreeRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

/**
 * Resolve a registered package's directory from the working tree root and the
 * registry, never from `cwd` itself. A registry or descriptor failure comes
 * back as its `gaia-packages:` message so the caller can refuse before it
 * writes anything.
 */
export const resolvePackageTarget = (
  cwd: string,
  name = 'frontend'
): PackageTarget => {
  const repoRoot = resolveTreeRoot(cwd);
  const loaded = loadPackages(repoRoot);

  if (!loaded.ok) {
    return {message: loaded.message, ok: false};
  }
  const found = loaded.packages.find((entry) => entry.name === name);

  if (found === undefined) {
    return {
      message: `gaia-packages: no package named "${name}" is registered. Next step: add it to .gaia/packages.json.`,
      ok: false,
    };
  }

  return {
    ok: true,
    packageDir: path.resolve(repoRoot, found.path),
    packagePath: found.path,
    repoRoot,
  };
};

/**
 * Normalize a user-supplied path to package-relative: a repo-relative value
 * that begins with the package path (`frontend/app/components/Form`) loses
 * that prefix, a package-relative one passes through.
 */
export const toPackageRelative = (
  value: string,
  packagePath: string
): string => {
  if (packagePath === '.') {
    return value;
  }

  return value.startsWith(`${packagePath}/`) ?
      value.slice(packagePath.length + 1)
    : value;
};
