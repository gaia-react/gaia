/**
 * Tests for `gaia mentorship _internal-assert-memory-rules`.
 *
 * Exercises the behavior the session-start hook relies on: install-on-enabled,
 * remove-on-disabled, never-fail-the-hook semantics.
 */
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {resolveStorageRoots} from '../../storage/paths.js';
import type {StorageRoots} from '../../storage/paths.js';
import {writeMentorshipConfig} from '../config.js';
import {run} from '../_internal-assert-memory-rules.js';
import {
  DISPLAY_RULE_FILE_NAME,
  DISPLAY_RULE_INDEX_LINE,
} from '../display-rule.js';
import {installDisplayRule} from '../display-rule-memory.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-assert-display-repo-'));
  const homeDirectory = mkdtempSync(
    path.join(tmpdir(), 'gaia-assert-display-home-')
  );
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

describe('mentorship _internal-assert-memory-rules', () => {
  let sandbox: Sandbox;
  let stdoutCapture: string[];
  let stdoutSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdoutCapture = [];
    stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation((chunk: unknown) => {
        stdoutCapture.push(typeof chunk === 'string' ? chunk : String(chunk));

        return true;
      });
  });

  afterEach(() => {
    sandbox.cleanup();
    stdoutSpy.mockRestore();
  });

  test('treats a missing config as disabled (pre-decision default)', () => {
    // `readMentorshipConfig` returns a pre-decision default with enabled=null
    // when the file is absent, which the asserter treats like disabled.
    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);
    const out = stdoutCapture.join('');
    expect(out).toContain('mentorship_assert_disabled');
  });

  test('emits mentorship_assert_skipped when config file is malformed', () => {
    // Seed a malformed config so readMentorshipConfig throws.
    const configDir = path.dirname(sandbox.roots.projectIdPath);
    mkdirSync(configDir, {mode: 0o755, recursive: true});
    writeFileSync(path.join(configDir, 'mentorship.json'), '{ broken json', {
      mode: 0o644,
    });

    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);
    const out = stdoutCapture.join('');
    expect(out).toContain('mentorship_assert_skipped');
    expect(out).toContain('config_unreadable');
  });

  test('removes the rule when mentorship is disabled', () => {
    installDisplayRule(sandbox.roots);
    writeMentorshipConfig({
      analyticsEnabled: false,
      decidedVia: 'gaia-init',
      enabled: false,
      roots: sandbox.roots,
    });

    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);
    const out = stdoutCapture.join('');
    expect(out).toContain('mentorship_assert_disabled');
    expect(
      existsSync(path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME))
    ).toBe(false);
  });

  test('installs the rule when mentorship is enabled and rule is missing', () => {
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'gaia-init',
      enabled: true,
      roots: sandbox.roots,
    });

    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);
    const out = stdoutCapture.join('');
    expect(out).toContain('mentorship_assert_ok');
    expect(out).toContain('"body_written":true');
    expect(out).toContain('"index_line_added":true');
    expect(
      existsSync(path.join(sandbox.roots.memoryDir, DISPLAY_RULE_FILE_NAME))
    ).toBe(true);
  });

  test('reports no-op when enabled and rule already in place', () => {
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'gaia-init',
      enabled: true,
      roots: sandbox.roots,
    });
    installDisplayRule(sandbox.roots);

    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);
    const out = stdoutCapture.join('');
    expect(out).toContain('mentorship_assert_ok');
    expect(out).toContain('"body_written":false');
    expect(out).toContain('"index_line_added":false');
  });

  test('memory dir is created lazily under a previously-empty home', () => {
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'gaia-init',
      enabled: true,
      roots: sandbox.roots,
    });
    expect(existsSync(sandbox.roots.memoryDir)).toBe(false);

    const exit = run([], {roots: sandbox.roots});
    expect(exit).toBe(0);

    expect(existsSync(sandbox.roots.memoryDir)).toBe(true);
    const indexBody = readFileSync(
      path.join(sandbox.roots.memoryDir, 'MEMORY.md'),
      'utf8'
    );
    expect(indexBody).toContain(DISPLAY_RULE_INDEX_LINE);
  });
});
