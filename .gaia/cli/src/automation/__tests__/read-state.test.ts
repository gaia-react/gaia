import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {run} from '../read-state.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const captureStdio = () => {
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

const validState = (sha: string): AutomationStateFile => ({
  cost_overage: false,
  last_run_at: '2026-05-01T00:00:00Z',
  last_run_cost: 0.42,
  last_run_sha: sha,
  last_run_trigger: 'cron',
  skip_count: 0,
  version: 1,
});

describe('automation read-state', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox('gaia-automation-read-state-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('emits JSON for an existing state', () => {
    sandbox.writeState('wiki', validState(sandbox.headSha));
    const exit = run(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const parsed = JSON.parse(stdio.outputs.join('')) as Record<
      string,
      unknown
    >;
    expect(parsed.last_run_trigger).toBe('cron');
  });

  it('exits non-zero with state_missing when file is absent', () => {
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_missing');
  });

  it('rejects unknown tool', () => {
    const exit = run(['unknown-tool'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('unknown tool');
  });

  it('rejects when no tool given', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });

  it('emits human report when --json absent', () => {
    sandbox.writeState('wiki', validState(sandbox.headSha));
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('last_run_trigger: cron');
  });
});
