/**
 * Tests for `gaia wiki log-prepend`.
 */
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './log-prepend.js';

const SAMPLE_LOG = `---
type: meta
title: Log
status: active
---

# Log

## [Unreleased]

- 2026-01-01 abc1234 - WORTHY: existing entry
`;

type Sandbox = {
  cleanup: () => void;
  logPath: string;
  root: string;
};

const setupSandbox = (logBody: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-log-prepend-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  const logPath = path.join(root, 'wiki', 'log.md');
  writeFileSync(logPath, logBody, 'utf8');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    logPath,
    root,
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

describe('wiki log-prepend', () => {
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

  test('prepends a SKIP entry under [Unreleased]', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(
      ['--sha', 'def5678', '--decision', 'SKIP', '--reason', 'test'],
      {cwd: sandbox.root, today: '2026-05-07'}
    );
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain('- 2026-05-07 def5678 SKIP — test');
    // The new entry should appear before the existing entry.
    const newIndex = written.indexOf('def5678');
    const oldIndex = written.indexOf('abc1234');
    expect(newIndex).toBeLessThan(oldIndex);
  });

  test('prepends a WORTHY entry', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(
      ['--sha', '0123456', '--decision', 'WORTHY', '--reason', 'added module'],
      {cwd: sandbox.root, today: '2026-05-07'}
    );
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain('- 2026-05-07 0123456 WORTHY — added module');
  });

  test('prepends a RE_ANCHOR entry', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(
      [
        '--sha',
        'feedbac',
        '--decision',
        'RE_ANCHOR',
        '--reason',
        're-anchored after history rewrite',
      ],
      {cwd: sandbox.root, today: '2026-05-07'}
    );
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain(
      '- 2026-05-07 feedbac RE_ANCHOR — re-anchored after history rewrite'
    );
  });

  test('rejects invalid --decision', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(
      ['--sha', 'def5678', '--decision', 'MAYBE', '--reason', 'oops'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--decision must be');
    expect(stdio.errors.join('')).toContain('RE_ANCHOR');
  });

  test('rejects missing --sha', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(['--decision', 'SKIP', '--reason', 'r'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--sha is required');
  });

  test('rejects missing --reason', () => {
    sandbox = setupSandbox(SAMPLE_LOG);

    const exit = run(['--sha', 'abc', '--decision', 'SKIP'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--reason is required');
  });

  test('exits 1 when frontmatter fence is missing', () => {
    sandbox = setupSandbox('# Log\n\nno frontmatter\n');

    const exit = run(['--sha', 'abc', '--decision', 'SKIP', '--reason', 'r'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('frontmatter');
  });

  test('exits 1 when frontmatter is unterminated', () => {
    sandbox = setupSandbox('---\ntype: meta\n\n# Log\n');

    const exit = run(['--sha', 'abc', '--decision', 'SKIP', '--reason', 'r'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('frontmatter');
  });

  test('inserts after closing fence when no H2 heading exists', () => {
    const minimal = '---\ntype: meta\n---\n\n# Log\n';
    sandbox = setupSandbox(minimal);

    const exit = run(
      ['--sha', 'def5678', '--decision', 'SKIP', '--reason', 'flat'],
      {cwd: sandbox.root, today: '2026-05-07'}
    );
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.logPath, 'utf8');
    expect(written).toContain('- 2026-05-07 def5678 SKIP — flat');
  });
});
