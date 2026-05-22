import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {automationStatePath} from '../paths.js';
import {run} from '../clear-overage.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const silenceStdio = () => {
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation(() => true);
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
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

const overageState = (sha: string): AutomationStateFile => ({
  cost_overage: true,
  last_run_at: '2026-05-01T00:00:00Z',
  last_run_cost: 6.5,
  last_run_sha: sha,
  last_run_trigger: 'cron',
  skip_count: 0,
  version: 1,
});

describe('automation clear-overage', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof silenceStdio>;

  beforeEach(() => {
    stdio = silenceStdio();
    sandbox = setupSandbox('gaia-automation-clear-overage-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('sets cost_overage=false while preserving siblings', () => {
    sandbox.writeState('wiki', overageState(sandbox.headSha));
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(automationStatePath(sandbox.root, 'wiki'), 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.cost_overage).toBe(false);
    expect(parsed.last_run_cost).toBe(6.5);
  });

  it('is a silent OK when cost_overage already false', () => {
    sandbox.writeState('wiki', {
      ...overageState(sandbox.headSha),
      cost_overage: false,
    });
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).toBe(0);
  });

  it('exits non-zero with state_missing when no state file', () => {
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_missing');
  });
});
