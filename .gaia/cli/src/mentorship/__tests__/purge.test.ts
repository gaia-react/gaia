import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../../storage/index.js';
import type {StorageRoots} from '../../storage/index.js';
import {writeMentorshipConfig} from '../config.js';
import {run as runPurge} from '../purge.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-purge-repo-'));
  const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-purge-home-'));
  const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
      rmSync(homeDirectory, {force: true, recursive: true});
    },
    homeDirectory,
    repoRoot,
    roots,
  };
};

const seedMentorshipFixture = async (roots: StorageRoots): Promise<void> => {
  await ensureMentorshipDirectories(roots);
  writeMentorshipConfig({
    analyticsEnabled: true,
    decidedVia: 'gaia-init',
    enabled: true,
    roots,
  });
  // Mentorship event file
  writeFileSync(
    path.join(roots.mentorshipDir, 'events-2026-05-06.jsonl'),
    `${JSON.stringify({event_id: 'fixture', schema_version: 1})}\n`,
    {mode: 0o600}
  );
  // profile.md
  writeFileSync(roots.profilePath, '# profile\n', {mode: 0o600});
  // install-id.txt — seeded with a known value; readOrCreateInstallId expects 26 chars.
  writeFileSync(roots.installIdPath, `${'A'.repeat(26)}\n`, {mode: 0o600});
  // analytics report
  mkdirSync(roots.analyticsDir, {mode: 0o755, recursive: true});
  writeFileSync(
    path.join(roots.analyticsDir, 'report-2026-05-06.json'),
    JSON.stringify({fixture: true})
  );
  // cloud file (must NOT be deleted)
  mkdirSync(roots.cloudDir, {mode: 0o755, recursive: true});
  writeFileSync(
    path.join(roots.cloudDir, 'events-2026-05-06.jsonl'),
    `${JSON.stringify({event_id: 'cloud-fixture'})}\n`
  );
};

describe('mentorship/purge', () => {
  let sandbox: Sandbox;
  let stderrSpy: ReturnType<typeof vi.spyOn>;
  let stdoutSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stderrSpy = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);
    stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation(() => true);
  });

  afterEach(() => {
    sandbox.cleanup();
    stderrSpy.mockRestore();
    stdoutSpy.mockRestore();
  });

  test('UAT-041: --yes deletes mentorship subtree, profile.md, analytics; preserves cloud', async () => {
    await seedMentorshipFixture(sandbox.roots);

    const exit = await runPurge(['--yes'], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);

    // Mentorship subtree gone.
    expect(existsSync(sandbox.roots.mentorshipDir)).toBe(false);

    // profile.md gone.
    expect(existsSync(sandbox.roots.profilePath)).toBe(false);

    // Analytics JSONs gone (directory may remain).
    const analyticsReport = path.join(
      sandbox.roots.analyticsDir,
      'report-2026-05-06.json'
    );
    expect(existsSync(analyticsReport)).toBe(false);

    // Cloud preserved.
    const cloudFile = path.join(
      sandbox.roots.cloudDir,
      'events-2026-05-06.jsonl'
    );
    expect(existsSync(cloudFile)).toBe(true);
  });

  test('UAT-041: regenerates install-id.txt with a fresh ULID', async () => {
    await seedMentorshipFixture(sandbox.roots);
    const oldId = readFileSync(sandbox.roots.installIdPath, 'utf8').trim();

    await runPurge(['--yes'], {roots: sandbox.roots});

    expect(existsSync(sandbox.roots.installIdPath)).toBe(true);
    const newId = readFileSync(sandbox.roots.installIdPath, 'utf8').trim();
    expect(newId).not.toBe(oldId);
    expect(newId).toHaveLength(26);
  });

  test('UAT-041: leaves mentorship.json choice intact (purge deletes data, not the choice)', async () => {
    await seedMentorshipFixture(sandbox.roots);
    const configPath = path.join(
      sandbox.repoRoot,
      '.gaia',
      'local',
      'mentorship.json'
    );
    expect(existsSync(configPath)).toBe(true);

    await runPurge(['--yes'], {roots: sandbox.roots});

    expect(existsSync(configPath)).toBe(true);
    const config = JSON.parse(readFileSync(configPath, 'utf8')) as {
      enabled: boolean;
    };
    expect(config.enabled).toBe(true);
  });

  test('UAT-041: prints structured stdout with code mentorship_purged + fresh_install_id', async () => {
    await seedMentorshipFixture(sandbox.roots);

    await runPurge(['--yes'], {roots: sandbox.roots});

    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    const purgedLine = lines.find((line) => line.includes('mentorship_purged'));
    expect(purgedLine).toBeDefined();
    const payload = JSON.parse(purgedLine ?? '{}') as Record<string, unknown>;
    expect(payload.code).toBe('mentorship_purged');
    expect(typeof payload.fresh_install_id).toBe('string');
    expect((payload.fresh_install_id as string).length).toBe(26);
  });

  test('no mentorship data → prints no_mentorship_data_to_purge and exits 0', async () => {
    const exit = await runPurge(['--yes'], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    expect(
      lines.some((line) => line.includes('no_mentorship_data_to_purge'))
    ).toBe(true);
  });

  test('UAT-045: --yes honors non-interactive bypass without prompting', async () => {
    await seedMentorshipFixture(sandbox.roots);
    // No stdin TTY in test runner; without --yes the prompt path returns
    // false and purge would no-op. With --yes it must proceed.
    const exit = await runPurge(['--yes'], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(existsSync(sandbox.roots.mentorshipDir)).toBe(false);
  });

  test('non-TTY without --yes refuses to proceed (mentorship_purge_cancelled)', async () => {
    await seedMentorshipFixture(sandbox.roots);

    const exit = await runPurge([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    // Mentorship subtree must remain intact.
    expect(existsSync(sandbox.roots.mentorshipDir)).toBe(true);
    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    expect(
      lines.some((line) => line.includes('mentorship_purge_cancelled'))
    ).toBe(true);
  });
});
