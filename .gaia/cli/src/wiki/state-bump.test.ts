/**
 * Tests for `gaia wiki state-bump`.
 *
 * Strategy: build a sandbox repo with a bare git init and a `wiki/.state.json`
 * file, then exercise the handler against that sandbox via the `cwd` option.
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
import {run} from './state-bump.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  statePath: string;
};

const setupSandbox = (initialState: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-state-bump-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  const statePath = path.join(root, 'wiki', '.state.json');
  writeFileSync(statePath, initialState, 'utf8');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    statePath,
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

describe('wiki state-bump', () => {
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

  test('updates an existing field, preserving sibling key order', () => {
    const initial = `${JSON.stringify(
      {
        version: 1,
        last_evaluated_sha: 'aaaaaaa',
        last_evaluated_at: '2026-01-01T00:00:00Z',
        last_consolidated_sha: 'bbbbbbb',
      },
      null,
      2
    )}\n`;
    sandbox = setupSandbox(initial);

    const exit = run(['last_evaluated_sha', 'cccccccc'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const written = readFileSync(sandbox.statePath, 'utf8');
    const parsed = JSON.parse(written) as Record<string, unknown>;
    expect(Object.keys(parsed)).toEqual([
      'version',
      'last_evaluated_sha',
      'last_evaluated_at',
      'last_consolidated_sha',
    ]);
    expect(parsed.last_evaluated_sha).toBe('cccccccc');
    expect(parsed.last_evaluated_at).toBe('2026-01-01T00:00:00Z');
    // Trailing newline preserved.
    expect(written.endsWith('\n')).toBe(true);
  });

  test('appends a new field at the end when absent', () => {
    const initial = `${JSON.stringify({version: 1, foo: 'bar'}, null, 2)}\n`;
    sandbox = setupSandbox(initial);

    const exit = run(['baz', 'qux'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(Object.keys(parsed)).toEqual(['version', 'foo', 'baz']);
    expect(parsed.baz).toBe('qux');
  });

  test('parses JSON-shaped values (number, boolean, array, object)', () => {
    const initial = JSON.stringify({version: 1});
    sandbox = setupSandbox(initial);

    expect(run(['count', '42'], {cwd: sandbox.root})).toBe(0);
    expect(run(['flag', 'true'], {cwd: sandbox.root})).toBe(0);
    expect(run(['list', '[1,2,3]'], {cwd: sandbox.root})).toBe(0);
    expect(run(['obj', '{"a":1}'], {cwd: sandbox.root})).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.count).toBe(42);
    expect(parsed.flag).toBe(true);
    expect(parsed.list).toEqual([1, 2, 3]);
    expect(parsed.obj).toEqual({a: 1});
  });

  test('round-trips strings that are not valid JSON literals', () => {
    sandbox = setupSandbox(JSON.stringify({version: 1}));
    expect(run(['name', 'hello world'], {cwd: sandbox.root})).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.name).toBe('hello world');
  });

  test('exits 1 when wiki/.state.json is malformed JSON', () => {
    sandbox = setupSandbox('{ not json');

    const exit = run(['foo', 'bar'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('not valid JSON');
  });

  test('exits 1 when wiki/.state.json is missing', () => {
    sandbox = setupSandbox('{}');
    rmSync(sandbox.statePath);

    const exit = run(['foo', 'bar'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('does not exist');
  });

  test('exits 1 with usage hint when no args supplied', () => {
    sandbox = setupSandbox('{}');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });

  test('exits 1 when only one positional supplied', () => {
    sandbox = setupSandbox('{}');

    const exit = run(['only-field'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('exactly');
  });

  test('idempotent: running twice with the same value leaves identical bytes', () => {
    const initial = `${JSON.stringify({version: 1, foo: 'bar'}, null, 2)}\n`;
    sandbox = setupSandbox(initial);

    expect(run(['foo', 'baz'], {cwd: sandbox.root})).toBe(0);
    const after1 = readFileSync(sandbox.statePath, 'utf8');
    expect(run(['foo', 'baz'], {cwd: sandbox.root})).toBe(0);
    const after2 = readFileSync(sandbox.statePath, 'utf8');
    expect(after1).toEqual(after2);
  });
});
