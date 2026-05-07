import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../../storage/index.js';
import type {StorageRoots} from '../../storage/index.js';
import {writeMentorshipConfig} from '../config.js';
import {run as runStatus} from '../status.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-status-repo-'));
  const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-status-home-'));
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

const lastStdoutPayload = (
  spy: ReturnType<typeof vi.spyOn>
): Record<string, unknown> => {
  const {calls} = spy.mock;
  const last = calls.at(-1);
  const raw = last === undefined ? '' : String(last[0]);

  return JSON.parse(raw) as Record<string, unknown>;
};

describe('mentorship/status', () => {
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

  test('UAT-042: pre-decision (no config file) returns documented defaults', () => {
    const exit = runStatus([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const payload = lastStdoutPayload(stdoutSpy);
    expect(payload.enabled).toBe(false);
    expect(payload.analytics_enabled).toBe(false);
    expect(payload.install_id).toBeNull();
    expect(payload.mentorship_dir).toBe(sandbox.roots.mentorshipDir);
    expect(payload.last_event_at).toBeNull();
    expect(payload.active_pattern_count).toBe(0);
    expect(payload.active_adaptation_count).toBe(0);
  });

  test('UAT-042: enabled state reflects config + install-id + last event timestamp', async () => {
    await ensureMentorshipDirectories(sandbox.roots);
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'gaia-init',
      enabled: true,
      roots: sandbox.roots,
    });
    const installId = '0'.repeat(26);
    writeFileSync(sandbox.roots.installIdPath, `${installId}\n`, {mode: 0o600});

    const eventTimestamp = '2026-05-07T12:34:56.789Z';
    const eventLine = JSON.stringify({
      event_id: 'fixture',
      event_type: 'uat_pass',
      schema_version: 1,
      timestamp: eventTimestamp,
    });
    writeFileSync(
      path.join(sandbox.roots.mentorshipDir, 'events-2026-05-07.jsonl'),
      `${eventLine}\n`,
      {mode: 0o600}
    );

    runStatus([], {roots: sandbox.roots});

    const payload = lastStdoutPayload(stdoutSpy);
    expect(payload.enabled).toBe(true);
    expect(payload.analytics_enabled).toBe(true);
    expect(payload.install_id).toBe(installId);
    expect(payload.last_event_at).toBe(eventTimestamp);
  });

  test('UAT-042: counts bullets under "Active patterns" / "Active adaptations" in profile.md', async () => {
    await ensureMentorshipDirectories(sandbox.roots);
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'gaia-init',
      enabled: true,
      roots: sandbox.roots,
    });

    const profile = [
      '# profile',
      '',
      '## Active patterns',
      '- articulation_gap (strength 0.42, N=12)',
      '- another_pattern (strength 0.51, N=15)',
      '',
      '## Active adaptations',
      '- po_socratic_depth_increased',
      '',
      '## Faded adaptations',
      '- old_adaptation',
      '',
    ].join('\n');
    writeFileSync(sandbox.roots.profilePath, profile, {mode: 0o600});

    runStatus([], {roots: sandbox.roots});

    const payload = lastStdoutPayload(stdoutSpy);
    expect(payload.active_pattern_count).toBe(2);
    expect(payload.active_adaptation_count).toBe(1);
  });

  test('UAT-042: works whether enabled or not (no throw on missing files)', () => {
    const exit = runStatus([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const payload = lastStdoutPayload(stdoutSpy);
    expect(payload.enabled).toBe(false);
    expect(payload.active_pattern_count).toBe(0);
  });

  test('UAT-042: top-level keys match the documented shape', () => {
    runStatus([], {roots: sandbox.roots});

    const payload = lastStdoutPayload(stdoutSpy);
    const keys = Object.keys(payload).toSorted((a, b) => a.localeCompare(b));
    expect(keys).toEqual([
      'active_adaptation_count',
      'active_pattern_count',
      'analytics_enabled',
      'enabled',
      'install_id',
      'last_event_at',
      'mentorship_dir',
    ]);
  });
});
