import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia-maintainer release exclude-regex`.
 *
 * Fixtures live in a `mkdtempSync` sandbox and are passed via
 * `--exclude-file`; none of these tests depend on the repo's real
 * `.gaia/release-exclude`.
 *
 * UAT-002's full-escape-class byte-equality is proven in
 * `exclude-parser-parity.test.ts` (which calls `renderExcludeRegex` and the
 * reference pipeline directly, neither of which validate); the fixtures
 * here that reach the emit path deliberately avoid rejected metacharacters
 * so they don't collide with the fail-closed / UAT-006 assertions below.
 */
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './exclude-regex.js';
import {renderExcludeRegex} from './manifest.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeExclude: (contents: string) => string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-exclude-regex-'));

  const writeExclude = (contents: string): string => {
    const target = path.join(root, 'release-exclude');
    writeFileSync(target, contents, 'utf8');

    return target;
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeExclude,
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

describe('release exclude-regex CLI', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('emits renderExcludeRegex output byte-for-byte for a validator-allowed, multi-segment fixture', () => {
    sandbox = setupSandbox();
    const fixture =
      '# comment\n\nwiki/hot.md\napp/routes/_public+\n.gaia/scripts\n';
    const excludePath = sandbox.writeExclude(fixture);

    const exit = run(['--exclude-file', excludePath], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe(renderExcludeRegex(fixture));
    expect(stdio.errors.join('')).toBe('');
  });

  test('empty case: comments/blanks-only source exits 0 with zero-byte stdout', () => {
    sandbox = setupSandbox();
    const excludePath = sandbox.writeExclude('# only a comment\n\n');

    const exit = run(['--exclude-file', excludePath], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');
  });

  test('fail-closed / UAT-006: a `*` metacharacter line exits 1, names the offending line, and prints no stdout', () => {
    sandbox = setupSandbox();
    const excludePath = sandbox.writeExclude('wiki/hot.md\nsrc/*.tmp\n');

    const exit = run(['--exclude-file', excludePath], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toBe('');
    const stderr = stdio.errors.join('');
    expect(stderr).toContain('exclude_compile_failed');
    expect(stderr).toContain('src/*.tmp');
  });

  test('fail-closed / UAT-006: a leading-indentation line exits 1, names the offending line, and prints no stdout', () => {
    sandbox = setupSandbox();
    const excludePath = sandbox.writeExclude('wiki/hot.md\n  indented-path\n');

    const exit = run(['--exclude-file', excludePath], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toBe('');
    const stderr = stdio.errors.join('');
    expect(stderr).toContain('exclude_compile_failed');
    expect(stderr).toContain('indented-path');
  });

  test('read failure: nonexistent --exclude-file exits 2 with a structured exclude_read_failed error', () => {
    sandbox = setupSandbox();
    const missingPath = path.join(sandbox.root, 'does-not-exist');

    const exit = run(['--exclude-file', missingPath], {cwd: sandbox.root});

    expect(exit).toBe(2);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toContain('exclude_read_failed');
  });

  test('--help prints HELP_TEXT and exits 0', () => {
    sandbox = setupSandbox();

    const exit = run(['--help'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'Usage: gaia-maintainer release exclude-regex'
    );
    expect(stdio.errors.join('')).toBe('');
  });

  test('--exclude-file with a missing value exits 1 with invalid_arguments', () => {
    sandbox = setupSandbox();

    const exit = run(['--exclude-file'], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });

  test('an unknown flag exits 1 with invalid_arguments', () => {
    sandbox = setupSandbox();

    const exit = run(['--bogus'], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });
});
