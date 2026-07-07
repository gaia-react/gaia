/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777` is
   the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for the `.gaia/local/sandbox.json` marker reader/writer
 * (UAT-012 mechanism).
 */
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  readSandboxMarker,
  resolveMarkerPath,
  writeSandboxMarker,
} from '../marker.js';
import type {SandboxMarker} from '../marker.js';

describe('sandbox marker', () => {
  let repoRoot: string;

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-sandbox-marker-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
  });

  test('readSandboxMarker returns null when the file is absent', () => {
    expect(readSandboxMarker(repoRoot)).toBeNull();
  });

  test('writeSandboxMarker then readSandboxMarker round-trips', () => {
    const marker: SandboxMarker = {
      capability: 'ready',
      outcome: 'enabled',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    };

    writeSandboxMarker(repoRoot, marker);

    expect(readSandboxMarker(repoRoot)).toEqual(marker);
  });

  test('writes at .gaia/local/sandbox.json with mode 644', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'declined',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });

    const filePath = resolveMarkerPath(repoRoot);
    expect(filePath).toBe(
      path.join(repoRoot, '.gaia', 'local', 'sandbox.json')
    );
    expect(existsSync(filePath)).toBe(true);
    expect(statSync(filePath).mode & 0o777).toBe(0o644);
  });

  test('writes atomically: no leftover temp file beside the target', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'unsupported',
      outcome: 'incapable',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });

    const parent = path.dirname(resolveMarkerPath(repoRoot));
    const entries = readdirSync(parent);
    expect(entries.some((entry) => entry.includes('.tmp.'))).toBe(false);
  });

  test('throws on an unexpected version (fail loud, not silent default)', () => {
    // First write ensures the parent dir exists, then corrupt the file.
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'enabled',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });
    writeFileSync(
      resolveMarkerPath(repoRoot),
      JSON.stringify({
        capability: 'ready',
        outcome: 'enabled',
        resolved_at: '2026-01-01T00:00:00.000Z',
        version: 2,
      }),
      {mode: 0o644}
    );

    expect(() => readSandboxMarker(repoRoot)).toThrow(/version/u);
  });

  test('throws on a malformed shape missing required fields', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'enabled',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });
    writeFileSync(resolveMarkerPath(repoRoot), JSON.stringify({version: 1}), {
      mode: 0o644,
    });

    expect(() => readSandboxMarker(repoRoot)).toThrow(
      /missing required fields/u
    );
  });

  test('throws on a present-but-off-vocabulary outcome/capability', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'enabled',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });
    writeFileSync(
      resolveMarkerPath(repoRoot),
      JSON.stringify({
        capability: 'ready',
        outcome: 'garbage',
        resolved_at: '2026-01-01T00:00:00.000Z',
        version: 1,
      }),
      {mode: 0o644}
    );

    expect(() => readSandboxMarker(repoRoot)).toThrow(
      /unknown outcome or capability/u
    );
  });

  test('overwrites the previous marker (write-temp-and-rename)', () => {
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'declined',
      resolved_at: '2026-01-01T00:00:00.000Z',
      version: 1,
    });
    writeSandboxMarker(repoRoot, {
      capability: 'ready',
      outcome: 'enabled',
      resolved_at: '2026-06-01T00:00:00.000Z',
      version: 1,
    });

    expect(readSandboxMarker(repoRoot)?.outcome).toBe('enabled');
  });
});
