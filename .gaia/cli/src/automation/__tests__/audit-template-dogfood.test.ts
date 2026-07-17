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
import {existsSync, readdirSync, readFileSync} from 'node:fs';
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

/**
 * Artifact drift-guard (tech-debt 730, extended from one file to all twelve):
 * `.gaia/cli/templates/workflows/` is a committed *build artifact*, a
 * byte-identical copy of `.gaia/cli/src/automation/templates/workflows/`
 * produced by `bundle:adopter`'s `cp -r .../workflows/. templates/workflows/`
 * step. Phase 2 of SPEC-045 makes these twelve files deliberately ownerless
 * for the Code Audit Team (a script pins them, so no member reviews them);
 * this suite is the pin that trade rests on. Both directories are tracked,
 * committed, maintainer-only paths (`.gaia/cli/src` is release-excluded
 * wholesale, which is also why this whole test file never runs on an
 * adopter clone), so unlike the dogfood test above, no `test.skipIf` gate
 * applies here: whenever this suite executes, both directories exist.
 */
const cpRemediation =
  'cp -r .gaia/cli/src/automation/templates/workflows/. .gaia/cli/templates/workflows/';

/** Recursively lists files under `dir` as paths relative to `dir`, sorted. */
const listFilesRelative = (dir: string): string[] => {
  const collect = (current: string): string[] =>
    readdirSync(current, {withFileTypes: true}).flatMap((entry) => {
      const full = path.join(current, entry.name);

      return entry.isDirectory() ? collect(full) : [full];
    });

  return collect(dir)
    .map((file) => path.relative(dir, file))
    .toSorted((a, b) => a.localeCompare(b));
};

const artifactRelativePath = (relative: string): string =>
  path.join('.gaia/cli/templates/workflows', relative);

const rmCommand = (relative: string): string =>
  `rm ${artifactRelativePath(relative)}`;

describe('audit-template artifact drift-guard (source vs. committed artifact, all templates)', () => {
  const repoRoot = resolveRepoRoot();
  // The source directory holding every template `workflowAuditTemplatePath()`
  // resolves one of; walking its parent reaches all twelve, partials included.
  const sourceDir = path.dirname(workflowAuditTemplatePath());
  const artifactDir = path.join(
    repoRoot,
    '.gaia',
    'cli',
    'templates',
    'workflows'
  );

  const sourceFiles = listFilesRelative(sourceDir);
  const artifactFiles = listFilesRelative(artifactDir);

  test('enumeration finds every template, partials included (floor, not a pin)', () => {
    // Today: 4 gaia-ci-*.yml workflows + code-review-audit.yml + 7 partials
    // under partials/ = 12. A walk that silently found zero files would pass
    // every per-file assertion below and test nothing, so assert the floor
    // explicitly rather than trusting the per-file checks to catch it.
    expect(sourceFiles.length).toBeGreaterThanOrEqual(12);
  });

  test('every source template is byte-identical to its committed artifact copy', () => {
    const stale = sourceFiles.filter((relative) => {
      const artifactPath = path.join(artifactDir, relative);

      if (!existsSync(artifactPath)) return true;

      return (
        readFileSync(artifactPath, 'utf8') !==
        readFileSync(path.join(sourceDir, relative), 'utf8')
      );
    });
    // Single-arg `expect`: fold the diagnosis into the compared value itself
    // so a failure's printed diff names the stale path(s) and the fix,
    // rather than reporting only `[] !== ['foo.tmpl']`.
    const actual =
      stale.length === 0 ?
        'no stale artifacts'
      : `stale committed template artifact(s): ${stale.map(artifactRelativePath).join(', ')}. Run: ${cpRemediation}`;

    expect(actual).toBe('no stale artifacts');
  });

  test('every committed artifact has a source counterpart (no orphaned artifact left behind)', () => {
    const sourceSet = new Set(sourceFiles);
    const orphans = artifactFiles.filter(
      (relative) => !sourceSet.has(relative)
    );
    const orphanPaths = orphans.map(artifactRelativePath).join(', ');
    const rmCommands = orphans.map(rmCommand).join('; ');
    const actual =
      orphans.length === 0 ?
        'no orphaned artifacts'
      : `orphaned template artifact(s) with no source counterpart (bundle:adopter's cp -r copies into the directory, it never prunes): ${orphanPaths}. Run: ${rmCommands}`;

    expect(actual).toBe('no orphaned artifacts');
  });
});
