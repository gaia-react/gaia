/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {z} from 'zod';
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveStorageRoots} from '../../storage/paths.js';
import {shouldShortCircuitComputeProfile} from '../compute-profile-guard.js';
import {
  CONFIG_FILENAME,
  isMentorshipEnabled,
  readMentorshipConfig,
  writeMentorshipConfig,
} from '../config.js';

const ISO_8601_UTC_MS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u;

const configPathFor = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', CONFIG_FILENAME);

describe('mentorship/config', () => {
  let repoRoot: string;
  let homeDirectory: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-mship-config-repo-'));
    homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-mship-config-home-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
    rmSync(homeDirectory, {force: true, recursive: true});
  });

  describe('readMentorshipConfig', () => {
    test('returns the pre-decision default when the file is absent', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      const config = readMentorshipConfig(roots);

      expect(config).toEqual({
        analytics: {enabled: false},
        decided_at: null,
        decided_via: null,
        enabled: null,
      });
    });

    test('does not create the file as a side effect of reading the absent default', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      readMentorshipConfig(roots);

      expect(existsSync(configPathFor(repoRoot))).toBe(false);
    });

    test('returns a fresh object each call (no shared mutation hazard)', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      const a = readMentorshipConfig(roots);
      const b = readMentorshipConfig(roots);

      expect(a).not.toBe(b);
      expect(a.analytics).not.toBe(b.analytics);
    });

    test('round-trips a valid written config', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);

      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('gaia-init');
      expect(config.decided_at).toMatch(ISO_8601_UTC_MS_RE);
    });

    test('throws on malformed JSON (corrupted file fails loud, not silently default)', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      // The first writeMentorshipConfig call ensures the parent dir exists.
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });
      // Corrupt the file: write a literal `{` (incomplete JSON object).
      writeFileSync(configPathFor(repoRoot), '{', {mode: 0o644});

      expect(() => readMentorshipConfig(roots)).toThrow(SyntaxError);
    });

    test('throws on a JSON object that does not match MentorshipConfigSchema', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });
      // Valid JSON, wrong shape: missing analytics, wrong enabled type.
      writeFileSync(
        configPathFor(repoRoot),
        JSON.stringify({enabled: 'maybe'}),
        {mode: 0o644}
      );

      expect(() => readMentorshipConfig(roots)).toThrow(z.ZodError);
    });
  });

  describe('writeMentorshipConfig', () => {
    test('produces a JSON file matching MentorshipConfigSchema with mode 644', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      const filePath = configPathFor(repoRoot);
      expect(existsSync(filePath)).toBe(true);
      expect(statSync(filePath).mode & 0o777).toBe(0o644);
      // Must round-trip through the schema validator.
      const parsed = readMentorshipConfig(roots);
      expect(parsed.enabled).toBe(false);
      expect(parsed.analytics.enabled).toBe(false);
      expect(parsed.decided_via).toBe('gaia-init');
    });

    test('stamps decided_at with an ISO-8601 UTC ms timestamp', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      const before = Date.now();

      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      const after = Date.now();
      const config = readMentorshipConfig(roots);
      expect(config.decided_at).toMatch(ISO_8601_UTC_MS_RE);
      const stamped = Date.parse(config.decided_at ?? '');
      expect(stamped).toBeGreaterThanOrEqual(before);
      expect(stamped).toBeLessThanOrEqual(after);
    });

    test('overwrites the previous config atomically (write-temp-and-rename)', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'mentorship-enable',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('mentorship-enable');
      // No leftover .tmp-<pid> sibling.
      const parent = path.dirname(configPathFor(repoRoot));
      const leftover = readFileSync(configPathFor(repoRoot), 'utf8');
      expect(leftover).toContain('"enabled": true');
      const entries = readdirSync(parent);
      expect(entries.some((entry) => entry.includes('.tmp-'))).toBe(false);
    });

    test('writes pretty-printed JSON terminated with a newline', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      const raw = readFileSync(configPathFor(repoRoot), 'utf8');
      expect(raw.endsWith('\n')).toBe(true);
      expect(raw).toContain('\n  "enabled"');
    });
  });

  describe('isMentorshipEnabled', () => {
    test('returns false when the file is absent', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      expect(isMentorshipEnabled(roots)).toBe(false);
    });

    test('returns false for the explicit pre-decision (enabled: null) state', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      // Hand-write the explicit-null shape to disk (writeMentorshipConfig
      // does not accept null, by design; only the absent-file path produces it).
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });
      writeFileSync(
        configPathFor(repoRoot),
        JSON.stringify({
          analytics: {enabled: false},
          decided_at: null,
          decided_via: null,
          enabled: null,
        }),
        {mode: 0o644}
      );

      expect(isMentorshipEnabled(roots)).toBe(false);
    });

    test('returns false when enabled is false', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      expect(isMentorshipEnabled(roots)).toBe(false);
    });

    test('returns true when enabled is true', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      expect(isMentorshipEnabled(roots)).toBe(true);
    });
  });

  describe('state-machine transitions', () => {
    test('pre-decision -> "Not now" -> disabled with analytics off', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(false);
      expect(config.analytics.enabled).toBe(false);
      expect(config.decided_via).toBe('gaia-init');
    });

    test('pre-decision -> "Yes" -> enabled with analytics on', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('gaia-init');
    });

    test('disabled -> mentorship enable -> enabled', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'mentorship-enable',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('mentorship-enable');
    });

    test('enabled -> mentorship disable -> disabled (analytics carried)', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });
      const previousAnalytics = readMentorshipConfig(roots).analytics.enabled;

      writeMentorshipConfig({
        analyticsEnabled: previousAnalytics,
        decidedVia: 'mentorship-disable',
        enabled: false,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(false);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('mentorship-disable');
    });

    test('analytics disable surgically (UAT-044): mentorship stays enabled, analytics flips off', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'mentorship-analytics-disable',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(false);
      expect(config.decided_via).toBe('mentorship-analytics-disable');
    });

    test('analytics enable: mentorship stays enabled, analytics flips on', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'mentorship-analytics-disable',
        enabled: true,
        roots,
      });

      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'mentorship-analytics-enable',
        enabled: true,
        roots,
      });

      const config = readMentorshipConfig(roots);
      expect(config.enabled).toBe(true);
      expect(config.analytics.enabled).toBe(true);
      expect(config.decided_via).toBe('mentorship-analytics-enable');
    });
  });

  describe('shouldShortCircuitComputeProfile', () => {
    test('returns true when the file is absent (pre-decision)', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

      expect(shouldShortCircuitComputeProfile(roots)).toBe(true);
    });

    test('returns true when enabled is false', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: false,
        decidedVia: 'gaia-init',
        enabled: false,
        roots,
      });

      expect(shouldShortCircuitComputeProfile(roots)).toBe(true);
    });

    test('returns false when enabled is true', () => {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      writeMentorshipConfig({
        analyticsEnabled: true,
        decidedVia: 'gaia-init',
        enabled: true,
        roots,
      });

      expect(shouldShortCircuitComputeProfile(roots)).toBe(false);
    });
  });
});
