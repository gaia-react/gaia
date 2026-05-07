/**
 * Tests for `gaia release runtime-deps`.
 */
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {extractPathRefs, run} from './runtime-deps.js';

type Sandbox = {
  cleanup: () => void;
  rootDir: string;
  writeFile: (relativePath: string, contents: string) => void;
  writeManifest: (files: Record<string, 'owned' | 'shared' | 'wiki-owned'>) => void;
};

const setupSandbox = (): Sandbox => {
  const rootDir = mkdtempSync(path.join(tmpdir(), 'gaia-runtime-deps-'));

  return {
    cleanup: () => {
      rmSync(rootDir, {force: true, recursive: true});
    },
    rootDir,
    writeFile: (relativePath, contents) => {
      const absolute = path.join(rootDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
    },
    writeManifest: (files) => {
      const absolute = path.join(rootDir, '.gaia', 'manifest.json');
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(
        absolute,
        `${JSON.stringify(
          {
            files,
            generated: '2026-05-08T00:00:00Z',
            version: '1.0.0',
          },
          null,
          2
        )}\n`,
        'utf8'
      );
    },
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('extractPathRefs', () => {
  test('extracts repo-relative paths from variable assignments', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"\n'
    );
    expect(refs.map((r) => r.path)).toContain('.gaia/scripts/check-updates.sh');
  });

  test('skips line-leading comments', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      '# A reference to .gaia/scripts/check-updates.sh in a comment.\nbash .gaia/cli/gaia\n'
    );
    expect(refs.map((r) => r.path)).toEqual(['.gaia/cli/gaia']);
  });

  test('handles bare path tokens in conditionals', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'if [ -x .gaia/cli/gaia ]; then\n  .gaia/cli/gaia run\nfi\n'
    );
    expect(refs.map((r) => r.path)).toEqual(['.gaia/cli/gaia', '.gaia/cli/gaia']);
  });

  test('does not match substrings inside larger paths', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'echo "not-a-leak/.gaia/cli/foo"\n'
    );
    expect(refs).toEqual([]);
  });

  test('trims trailing punctuation', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'echo .gaia/cli/gaia.\n'
    );
    expect(refs.map((r) => r.path)).toEqual(['.gaia/cli/gaia']);
  });

  test('extracts multiple occurrences on the same line', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'cp .gaia/cli/gaia .claude/hooks/x.sh\n'
    );
    expect(refs.map((r) => r.path)).toEqual([
      '.gaia/cli/gaia',
      '.claude/hooks/x.sh',
    ]);
  });
});

describe('release runtime-deps CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('passes when shipped scripts only reference manifested paths', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/scripts/check-updates.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/gaia-statusline.sh',
      [
        '#!/usr/bin/env bash',
        'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
        'if [ -x .gaia/cli/gaia ]; then bash "$CHECK_SCRIPT"; fi',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('runtime-dependency leaks: none');
  });

  test('flags references to release-excluded paths', () => {
    // Manifest excludes .gaia/scripts/ — that directory is release-excluded.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/gaia-statusline.sh',
      [
        '#!/usr/bin/env bash',
        'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
        'bash "$CHECK_SCRIPT"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const out = stdio.outputs.join('');
    expect(out).toContain('.gaia/scripts/check-updates.sh');
    expect(out).toContain('.gaia/statusline/gaia-statusline.sh:2');
  });

  test('allowlists adopter-owned sentinels', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/wiki-session-start.sh',
      [
        '#!/usr/bin/env bash',
        'cat .gaia/manifest.json',
        'cat .gaia/VERSION',
        'cat wiki/hot.md',
        'cat wiki/log.md',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('allowlists runtime-allocated prefixes (.gaia/local, .gaia/cache)', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/wiki-session-start.sh',
      [
        '#!/usr/bin/env bash',
        'rm -f .gaia/cache/coaching-active.txt',
        'STATE_FILE="$PROJECT_ROOT/.gaia/local/setup-state.json"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('allowlists per-session marker files', () => {
    sandbox.writeManifest({});
    sandbox.writeFile(
      '.claude/hooks/check-i18n-strings.sh',
      [
        '#!/usr/bin/env bash',
        'marker=".claude/i18n-strings-checked"',
        'touch ".claude/wiki-drift-checked"',
        'echo > ".claude/wiki-safety-checked"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('--json emits structured report', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/foo.sh',
      'bash .gaia/scripts/missing.sh\n'
    );

    const exit = run(['--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: ReadonlyArray<{file: string; line: number; path: string}>;
      scanned_files: readonly string[];
    };
    expect(parsed.leaks).toHaveLength(1);
    expect(parsed.leaks[0]?.path).toBe('.gaia/scripts/missing.sh');
    expect(parsed.scanned_files).toContain('.gaia/statusline/foo.sh');
  });

  test('exits 0 when there are no shipped script directories', () => {
    sandbox.writeManifest({});

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('exits 2 when manifest is missing', () => {
    sandbox.writeFile('.gaia/statusline/foo.sh', 'bash .gaia/cli/gaia\n');

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_load_failed');
  });

  test('--staging scans inside the staging dir', () => {
    const stagingDir = path.join(sandbox.rootDir, 'staging');
    mkdirSync(stagingDir, {recursive: true});
    mkdirSync(path.join(stagingDir, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/manifest.json'),
      `${JSON.stringify(
        {files: {'.gaia/cli/gaia': 'owned'}, generated: '2026-05-08T00:00:00Z', version: '1.0.0'},
        null,
        2
      )}\n`,
      'utf8'
    );
    mkdirSync(path.join(stagingDir, '.gaia/statusline'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/statusline/foo.sh'),
      'bash .gaia/cli/gaia\n',
      'utf8'
    );

    const exit = run(['--staging', stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('rejects unknown flags', () => {
    sandbox.writeManifest({});
    const exit = run(['--bogus'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('skips self-references', () => {
    sandbox.writeManifest({});
    sandbox.writeFile(
      '.gaia/statusline/preferred-base.sh',
      [
        '#!/usr/bin/env bash',
        '# This file is .gaia/statusline/preferred-base.sh',
        'echo .gaia/statusline/preferred-base.sh',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });
});
