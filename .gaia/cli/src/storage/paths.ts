import {execSync} from 'node:child_process';
import path from 'node:path';

export type StorageRoots = {
  projectIdPath: string;
};

type ResolveArgs = {
  homeDir?: string;
  repoRoot?: string;
};

let cachedRepoRoot: string | undefined;

const resolveRepoRoot = (): string => {
  if (cachedRepoRoot !== undefined) {
    return cachedRepoRoot;
  }

  try {
    // canonical PATH tool for repo-root resolution; matches the rest of the
    // project's tooling (husky, lint-staged) which also assumes git on PATH.
    const out = execSync('git rev-parse --show-toplevel', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    cachedRepoRoot = out.length > 0 ? out : process.cwd();
  } catch {
    cachedRepoRoot = process.cwd();
  }

  return cachedRepoRoot;
};

export const resolveStorageRoots = (args?: ResolveArgs): StorageRoots => {
  const repoRoot = args?.repoRoot ?? resolveRepoRoot();
  const projectIdPath = path.join(repoRoot, '.gaia', 'local', '.project-id');

  return {
    projectIdPath,
  };
};
