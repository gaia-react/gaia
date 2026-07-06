import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia init bootstrap-env`.
 */
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './bootstrap-env.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-bootstrap-env-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
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

describe('gaia init bootstrap-env', () => {
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

  test('copies .env.example to .env when .env is absent', () => {
    sandbox = setupSandbox();
    writeFileSync(path.join(sandbox.root, '.env.example'), 'FOO=bar\n', 'utf8');

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(sandbox.root, '.env'))).toBe(true);
    expect(readFileSync(path.join(sandbox.root, '.env'), 'utf8')).toBe(
      'FOO=bar\n'
    );
    expect(existsSync(path.join(sandbox.root, '.env.example'))).toBe(true);
    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('bootstrap-env');
  });

  test('no-op when .env already exists', () => {
    sandbox = setupSandbox();
    writeFileSync(path.join(sandbox.root, '.env'), 'EXISTING=1\n', 'utf8');
    writeFileSync(path.join(sandbox.root, '.env.example'), 'FOO=bar\n', 'utf8');

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(readFileSync(path.join(sandbox.root, '.env'), 'utf8')).toBe(
      'EXISTING=1\n'
    );
    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('bootstrap-env');
  });

  test('no-op when neither .env nor .env.example exists', () => {
    sandbox = setupSandbox();

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(sandbox.root, '.env'))).toBe(false);
    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('bootstrap-env');
  });

  test('idempotent: re-running is safe', () => {
    sandbox = setupSandbox();
    writeFileSync(path.join(sandbox.root, '.env.example'), 'FOO=bar\n', 'utf8');

    run([], {cwd: sandbox.root});
    const second = run([], {cwd: sandbox.root});

    expect(second).toBe(0);
    expect(readFileSync(path.join(sandbox.root, '.env'), 'utf8')).toBe(
      'FOO=bar\n'
    );
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox();
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
