/**
 * Maintainer drift-guard: asserts that the in-tree
 * `.github/workflows/code-review-audit.yml` is byte-identical to the
 * canonical template at `workflowAuditTemplatePath()`.
 *
 * In an adopter clone the in-tree workflow is release-excluded and absent,
 * so the test skips gracefully. In the maintainer clone both files exist and
 * must match; any divergence means either the live gate or the install
 * source was edited without updating the other.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {describe, expect, it} from 'vitest';
import {workflowAuditTemplatePath} from '../paths.js';

const resolveRepoRoot = (): string => {
  // Walk up from this file's location to find the repo root (contains .git).
  const here = fileURLToPath(import.meta.url);
  let dir = path.dirname(here);

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

describe('audit-template dogfood drift-guard', () => {
  it('in-tree code-review-audit.yml is byte-identical to the canonical template', () => {
    const repoRoot = resolveRepoRoot();
    const inTreePath = path.join(
      repoRoot,
      '.github',
      'workflows',
      'code-review-audit.yml'
    );

    if (!existsSync(inTreePath)) {
      // Adopter clone: the workflow is release-excluded; skip.
      return;
    }

    const inTree = readFileSync(inTreePath, 'utf8');
    const template = readFileSync(workflowAuditTemplatePath(), 'utf8');

    expect(inTree).toBe(template);
  });
});
