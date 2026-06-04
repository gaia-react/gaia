/**
 * Tests for `gaia wiki frontmatter`.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {findFrontmatterGaps, run} from './frontmatter.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-frontmatter-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeFile: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
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

describe('wiki frontmatter', () => {
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

  test('flags a page missing status', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      '---\ntype: concept\n---\n\n# Foo\n\nBody.\n'
    );

    const gaps = findFrontmatterGaps(sandbox.root);
    expect(gaps).toEqual([{missing: ['status'], path: 'wiki/concepts/Foo.md'}]);
  });

  test('flags a page missing both type and status', () => {
    sandbox.writeFile(
      'wiki/concepts/Bare.md',
      '---\ntitle: Bare\n---\n\n# Bare\n\nBody.\n'
    );

    const gaps = findFrontmatterGaps(sandbox.root);
    expect(gaps).toEqual([
      {missing: ['type', 'status'], path: 'wiki/concepts/Bare.md'},
    ]);
  });

  test('flags a page with no frontmatter block at all', () => {
    sandbox.writeFile('wiki/concepts/None.md', '# None\n\nNo frontmatter.\n');

    const gaps = findFrontmatterGaps(sandbox.root);
    expect(gaps).toEqual([
      {missing: ['type', 'status'], path: 'wiki/concepts/None.md'},
    ]);
  });

  test('treats a null required field as missing', () => {
    sandbox.writeFile(
      'wiki/concepts/Null.md',
      '---\ntype: concept\nstatus: ~\n---\n\n# Null\n'
    );

    const gaps = findFrontmatterGaps(sandbox.root);
    expect(gaps).toEqual([
      {missing: ['status'], path: 'wiki/concepts/Null.md'},
    ]);
  });

  test('does not flag a page carrying both required fields', () => {
    sandbox.writeFile(
      'wiki/concepts/Good.md',
      '---\ntype: concept\nstatus: stable\n---\n\n# Good\n'
    );

    expect(findFrontmatterGaps(sandbox.root)).toEqual([]);
  });

  test('skips wiki/meta/** audit artifacts', () => {
    sandbox.writeFile(
      'wiki/meta/lint-report-2026-05-07.md',
      '# Lint Report\n\nNo frontmatter convention here.\n'
    );

    expect(findFrontmatterGaps(sandbox.root)).toEqual([]);
  });

  test('CLI prints "path: missing ..." lines', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      '---\ntype: concept\n---\n\n# Foo\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe(
      'wiki/concepts/Foo.md: missing status'
    );
  });

  test('CLI prints a clean message when there are no gaps', () => {
    sandbox.writeFile(
      'wiki/concepts/Good.md',
      '---\ntype: concept\nstatus: stable\n---\n\n# Good\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('No frontmatter gaps found.');
  });

  test('--json emits a structured gaps object', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      '---\ntype: concept\n---\n\n# Foo\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      gaps: ReadonlyArray<{missing: string[]; path: string}>;
    };
    expect(parsed.gaps).toEqual([
      {missing: ['status'], path: 'wiki/concepts/Foo.md'},
    ]);
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('exits 0 when there is no wiki/ directory', () => {
    rmSync(path.join(sandbox.root, 'wiki'), {force: true, recursive: true});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('No frontmatter gaps found.');
  });
});
