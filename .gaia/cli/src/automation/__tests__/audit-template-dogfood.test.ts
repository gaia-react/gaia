import {describe, expect, test} from 'vitest';
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
  const repoRoot = resolveRepoRoot();
  const inTreePath = path.join(
    repoRoot,
    '.github',
    'workflows',
    'code-review-audit.yml'
  );
  // Adopter clone: the workflow is release-excluded; skip gracefully.
  const inTreeExists = existsSync(inTreePath);

  test.skipIf(!inTreeExists)(
    'in-tree code-review-audit.yml is byte-identical to the canonical template',
    () => {
      const inTree = readFileSync(inTreePath, 'utf8');
      const template = readFileSync(workflowAuditTemplatePath(), 'utf8');

      expect(inTree).toBe(template);
    }
  );

  test('instructs the audit agent to emit the machine-readable findings block', () => {
    const template = readFileSync(workflowAuditTemplatePath(), 'utf8');

    // The tally pass parses findings from the PR comment via these stable
    // sentinels; freezing them in the prompt is the contract anchor.
    expect(template).toContain('<!-- gaia-harden:findings:start -->');
    expect(template).toContain('<!-- gaia-harden:findings:end -->');
    // The finding_class values come from the per-bucket convention in the
    // agent definition, not a second one re-derived in the workflow.
    expect(template).toContain('.claude/agents/code-audit-frontend.md');
  });
});
