import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {automationStatePath} from '../paths.js';
import {run} from '../record-overage.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const silenceStdio = () => {
  const errors: string[] = [];
  const stdoutSpy = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    errors.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });

  return {
    errors,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const baseState = (sha: string): AutomationStateFile => ({
  cost_overage: false,
  last_run_at: '2026-05-01T00:00:00Z',
  last_run_cost: 1.5,
  last_run_sha: sha,
  last_run_trigger: 'cron',
  skip_count: 2,
  version: 1,
});

describe('automation record-overage', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof silenceStdio>;

  beforeEach(() => {
    stdio = silenceStdio();
    sandbox = setupSandbox('gaia-automation-record-overage-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('sets cost_overage and last_run_cost while preserving siblings', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--cost', '6.50'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(automationStatePath(sandbox.root, 'wiki'), 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.cost_overage).toBe(true);
    expect(parsed.last_run_cost).toBe(6.5);
    // Other fields preserved.
    expect(parsed.skip_count).toBe(2);
    expect(parsed.last_run_trigger).toBe('cron');
  });

  it('exits non-zero with state_missing when no state file exists', () => {
    const exit = run(['wiki', '--cost', '6.50'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_missing');
  });

  it('rejects negative cost', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--cost', '-1'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
  });
});
