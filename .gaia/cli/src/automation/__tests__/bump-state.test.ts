import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {automationStatePath} from '../paths.js';
import {run} from '../bump-state.js';
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
  last_run_cost: 0,
  last_run_sha: sha,
  last_run_trigger: 'cron',
  skip_count: 2,
  version: 1,
});

const readWiki = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(automationStatePath(root, 'wiki'), 'utf8')) as Record<
    string,
    unknown
  >;

describe('automation bump-state', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof silenceStdio>;

  beforeEach(() => {
    stdio = silenceStdio();
    sandbox = setupSandbox('gaia-automation-bump-state-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('increments skip_count', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--field', 'skip_count', '--value', '3'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readWiki(sandbox.root).skip_count).toBe(3);
  });

  it('updates a string field', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--field', 'last_run_trigger', '--value', '"force"'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readWiki(sandbox.root).last_run_trigger).toBe('force');
  });

  it('treats unparseable JSON value as a raw string', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--field', 'last_run_trigger', '--value', 'force'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readWiki(sandbox.root).last_run_trigger).toBe('force');
  });

  it('rejects post-bump shape that violates schema', () => {
    sandbox.writeState('wiki', baseState(sandbox.headSha));
    const exit = run(['wiki', '--field', 'skip_count', '--value', '-5'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_malformed');
  });

  it('exits non-zero when state file missing', () => {
    const exit = run(['wiki', '--field', 'skip_count', '--value', '3'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_missing');
  });
});
