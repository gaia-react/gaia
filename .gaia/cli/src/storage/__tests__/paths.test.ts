/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
/* eslint-disable sonarjs/publicly-writable-directories -- the *constant-string*
   tests exercise path-construction logic with `/tmp/fake-...` synthetic
   prefixes; nothing is written. The runtime tests use mkdtempSync(tmpdir())
   which is the recommended sandboxing pattern. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {existsSync, mkdtempSync, rmSync, statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  deriveClaudeSlug,
  ensureCloudDirs as ensureCloudDirectories,
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../paths.js';

describe('resolveStorageRoots', () => {
  test('produces the SPEC-mandated paths under repoRoot + homeDir', () => {
    const repoRoot = '/tmp/fake-repo';
    const homeDirectory = '/tmp/fake-home';
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    expect(roots.cloudDir).toBe('/tmp/fake-repo/.gaia/local/telemetry/cloud');
    expect(roots.analyticsDir).toBe(
      '/tmp/fake-repo/.gaia/local/telemetry/analytics'
    );
    expect(roots.mentorshipDir).toBe(
      '/tmp/fake-home/.claude/projects/-tmp-fake-repo/gaia/telemetry/mentorship'
    );
    expect(roots.installIdPath).toBe(
      '/tmp/fake-home/.claude/projects/-tmp-fake-repo/gaia/install-id.txt'
    );
    expect(roots.projectIdPath).toBe('/tmp/fake-repo/.gaia/local/.project-id');
    expect(roots.profilePath).toBe(
      '/tmp/fake-home/.claude/projects/-tmp-fake-repo/gaia/profile.md'
    );
    expect(roots.memoryDir).toBe(
      '/tmp/fake-home/.claude/projects/-tmp-fake-repo/memory'
    );
  });

  test('deriveClaudeSlug matches the observed Claude convention', () => {
    expect(deriveClaudeSlug('/Users/you/projects/my-app')).toBe(
      '-Users-you-projects-my-app'
    );
  });
});

describe('ensureCloudDirs', () => {
  let repoRoot: string;
  let homeDirectory: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-paths-repo-'));
    homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-paths-home-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
    rmSync(homeDirectory, {force: true, recursive: true});
  });

  test('creates cloud + analytics directories with mode 755 if absent', async () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    await ensureCloudDirectories(roots);

    expect(existsSync(roots.cloudDir)).toBe(true);
    expect(existsSync(roots.analyticsDir)).toBe(true);
    expect(statSync(roots.cloudDir).mode & 0o777).toBe(0o755);
    expect(statSync(roots.analyticsDir).mode & 0o777).toBe(0o755);
  });

  test('is idempotent (no-op when dirs already exist)', async () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    await ensureCloudDirectories(roots);
    await ensureCloudDirectories(roots);

    expect(existsSync(roots.cloudDir)).toBe(true);
    expect(existsSync(roots.analyticsDir)).toBe(true);
  });
});

describe('ensureMentorshipDirs', () => {
  let repoRoot: string;
  let homeDirectory: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-paths-repo-'));
    homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-paths-home-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
    rmSync(homeDirectory, {force: true, recursive: true});
  });

  test('creates the slug -> gaia -> telemetry -> mentorship chain at mode 700', async () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    await ensureMentorshipDirectories(roots);

    expect(existsSync(roots.mentorshipDir)).toBe(true);
    const telemetryDirectory = path.dirname(roots.mentorshipDir);
    const gaiaDirectory = path.dirname(telemetryDirectory);
    const slugDirectory = path.dirname(gaiaDirectory);

    expect(statSync(slugDirectory).mode & 0o777).toBe(0o700);
    expect(statSync(gaiaDirectory).mode & 0o777).toBe(0o700);
    expect(statSync(telemetryDirectory).mode & 0o777).toBe(0o700);
    expect(statSync(roots.mentorshipDir).mode & 0o777).toBe(0o700);
  });

  test('is idempotent on second invocation', async () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

    await ensureMentorshipDirectories(roots);
    await ensureMentorshipDirectories(roots);

    expect(existsSync(roots.mentorshipDir)).toBe(true);
    expect(statSync(roots.mentorshipDir).mode & 0o777).toBe(0o700);
  });
});
