/**
 * Repo-root fixture locator for tests.
 *
 * Walks up from a test file's own `import.meta.url` until it finds a `.git`
 * directory. Deliberately independent of `process.cwd()` (the test runner's
 * invocation directory varies) and deliberately NOT the git-based
 * `resolveRepoRoot` (`util/repo-root.ts`): a vitest fixture locator should
 * not shell out to git.
 */
import {existsSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const resolveRepoRootFromImportMeta = (
  importMetaUrl: string
): string => {
  let dir = path.dirname(fileURLToPath(importMetaUrl));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};
