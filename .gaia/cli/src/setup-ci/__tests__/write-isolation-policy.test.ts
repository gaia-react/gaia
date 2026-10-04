import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {
  ISOLATION_POLICIES,
  projectConfigPath,
  readProjectConfig,
} from '../../schemas/project-config.js';
import {run} from '../write-isolation-policy.js';
import {assertStatusOk, setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readRaw = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(projectConfigPath(root), 'utf8')) as Record<
    string,
    unknown
  >;

// Built at runtime so the retired config file name never lands as a literal.
const retiredConfigPath = (root: string): string =>
  path.join(root, '.gaia', ['automation', 'json'].join('.'));

describe('setup-ci write-isolation-policy', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-write-isolation-policy-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('creates .gaia/project.json when absent, never the retired config', () => {
    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      '{\n  "version": 1,\n  "isolation_policy": "prefer-worktree"\n}\n'
    );
    expect(existsSync(retiredConfigPath(sandbox.root))).toBe(false);
  });

  test('a second writer keeps the first key, and an unknown key survives', () => {
    sandbox.writeProjectConfig({
      some_future_key: 'x',
      version: 1,
    });

    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = readRaw(sandbox.root);
    expect(written.some_future_key).toBe('x');
    expect(written.isolation_policy).toBe('prefer-worktree');
    expect(existsSync(retiredConfigPath(sandbox.root))).toBe(false);
  });

  test.each(ISOLATION_POLICIES)('writes isolation_policy: %s', (value) => {
    const exit = run([value], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const result = readProjectConfig(sandbox.root);
    assertStatusOk(result);
    expect(result.config.isolation_policy).toBe(value);
  });

  test('overwrites an existing value (the --reconfigure path)', () => {
    sandbox.writeProjectConfig({
      isolation_policy: 'always-worktree',
      version: 1,
    });

    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    expect(readRaw(sandbox.root).isolation_policy).toBe('prefer-worktree');
  });

  test('emits {isolation_policy} JSON on success', () => {
    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.isolation_policy).toBe('prefer-worktree');
  });

  test('exits CONFIG_INVALID, names the file, and leaves a malformed file unchanged', () => {
    const malformed = '{not json';
    writeFileSync(projectConfigPath(sandbox.root), malformed, 'utf8');

    const exit = run(['prefer-worktree'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(stdio.err.join('')).toContain('config_malformed');
    expect(stdio.err.join('')).toContain('project.json');
    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      malformed
    );
  });

  test('exits non-zero on an unrecognized value and leaves the file byte-identical', () => {
    sandbox.writeProjectConfig({some_future_key: 'x', version: 1});
    const before = readFileSync(projectConfigPath(sandbox.root), 'utf8');

    const exit = run(['sometimes'], {cwd: sandbox.root});
    expect(exit).not.toBe(EXIT_CODES.OK);
    expect(stdio.err.join('')).toContain('unrecognized isolation policy');
    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(before);
  });

  test('an unrecognized value creates no file when none existed', () => {
    const exit = run(['sometimes'], {cwd: sandbox.root});
    expect(exit).not.toBe(EXIT_CODES.OK);
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('rejects unexpected extra arguments', () => {
    const exit = run(['prefer-worktree', '--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unexpected argument');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
