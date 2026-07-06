import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia setup` CLI surface.
 *
 * Strategy: tmp git repo per test, exercise status / mark-step / finalize
 * sequentially against `.gaia/local/setup-state.json`.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run as runFinalize} from '../finalize.js';
import {run as runMarkStep} from '../mark-step.js';
import {run as runStatus} from '../status.js';
import {SETUP_STEPS} from '../util/state-file.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  statePath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-setup-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    statePath: path.join(root, '.gaia', 'local', 'setup-state.json'),
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

describe('gaia setup status', () => {
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

  test('reports incomplete with all steps pending when no state file exists', () => {
    const exit = runStatus(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const out = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(out.complete).toBe(false);
    expect(out.completed_steps).toEqual([]);
    expect(out.pending_steps).toEqual([...SETUP_STEPS]);
  });

  test('human format mentions /setup-gaia for incomplete state', () => {
    const exit = runStatus([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const out = stdio.outputs.join('');
    expect(out).toContain('Setup is incomplete');
    expect(out).toContain('/setup-gaia');
  });

  test('rejects unknown flags', () => {
    const exit = runStatus(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});

describe('gaia setup mark-step', () => {
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

  test('creates the state file on first invocation', () => {
    expect(existsSync(sandbox.statePath)).toBe(false);

    const exit = runMarkStep(['install-tools'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(existsSync(sandbox.statePath)).toBe(true);
    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_steps).toEqual(['install-tools']);
    expect(parsed.completed_at).toBeNull();
    expect(parsed.started_at).toEqual(expect.any(String));
  });

  test('appends new steps and is idempotent on repeat', () => {
    runMarkStep(['install-tools'], {cwd: sandbox.root});
    runMarkStep(['install-plugins'], {cwd: sandbox.root});
    runMarkStep(['install-tools'], {cwd: sandbox.root});

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_steps).toEqual([
      'install-tools',
      'install-plugins',
    ]);
  });

  test('rejects an unknown step', () => {
    const exit = runMarkStep(['nope'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown step');
  });

  test('rejects when no step is supplied', () => {
    const exit = runMarkStep([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });
});

describe('gaia setup finalize', () => {
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

  test('refuses to finalize when steps are pending', () => {
    runMarkStep(['install-tools'], {cwd: sandbox.root});
    const exit = runFinalize([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('setup_steps_pending');
  });

  test('finalizes after every step is marked', () => {
    for (const step of SETUP_STEPS) {
      runMarkStep([step], {cwd: sandbox.root});
    }

    const fixedNow = new Date('2026-05-07T12:00:00.000Z');
    const exit = runFinalize([], {cwd: sandbox.root, now: () => fixedNow});
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_at).toBe('2026-05-07T12:00:00.000Z');
  });

  test('--force allows finalize with pending steps', () => {
    runMarkStep(['install-tools'], {cwd: sandbox.root});

    const fixedNow = new Date('2026-05-07T12:00:00.000Z');
    const exit = runFinalize(['--force'], {
      cwd: sandbox.root,
      now: () => fixedNow,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_at).toBe('2026-05-07T12:00:00.000Z');
  });

  test('finalize from scratch with --force creates a complete state file', () => {
    expect(existsSync(sandbox.statePath)).toBe(false);

    const fixedNow = new Date('2026-05-07T12:00:00.000Z');
    const exit = runFinalize(['--force'], {
      cwd: sandbox.root,
      now: () => fixedNow,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(sandbox.statePath, 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.completed_at).toBe('2026-05-07T12:00:00.000Z');
    expect(parsed.completed_steps).toEqual([]);
  });

  test('reports complete via status after finalize', () => {
    for (const step of SETUP_STEPS) {
      runMarkStep([step], {cwd: sandbox.root});
    }

    runFinalize([], {cwd: sandbox.root});

    stdio.outputs.length = 0;
    runStatus(['--json'], {cwd: sandbox.root});
    const out = JSON.parse(stdio.outputs.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(out.complete).toBe(true);
  });
});

describe('state file robustness', () => {
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

  const writeStateJson = (value: unknown): void => {
    const stateDirectory = path.dirname(sandbox.statePath);
    execFileSync('mkdir', ['-p', stateDirectory]);
    writeFileSync(sandbox.statePath, JSON.stringify(value), 'utf8');
  };

  test('rejects malformed state file', () => {
    const stateDirectory = path.dirname(sandbox.statePath);
    execFileSync('mkdir', ['-p', stateDirectory]);
    writeFileSync(sandbox.statePath, '{ broken', 'utf8');

    const exit = runStatus(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('state_malformed');
  });

  test('surfaces an unrecognized completed step instead of dropping it', () => {
    writeStateJson({
      completed_at: null,
      completed_steps: ['install-tools', 'not-a-real-step'],
      started_at: '2026-05-07T11:00:00.000Z',
      version: 1,
    });

    const exit = runStatus(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('state_malformed');
    expect(stdio.errors.join('')).toContain('not-a-real-step');
  });

  test('rejects a state file with a missing started_at', () => {
    writeStateJson({
      completed_at: null,
      completed_steps: ['install-tools'],
      version: 1,
    });

    const exit = runStatus(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('started_at');
  });
});
