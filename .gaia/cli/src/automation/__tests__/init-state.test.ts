import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {automationStatePath} from '../paths.js';
import {run} from '../init-state.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const captureStderr = () => {
  const errors: string[] = [];
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation(() => true);

  return {
    errors,
    restore: () => {
      stderrSpy.mockRestore();
      stdoutSpy.mockRestore();
    },
  };
};

describe('automation init-state', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStderr>;

  beforeEach(() => {
    stdio = captureStderr();
    sandbox = setupSandbox('gaia-automation-init-state-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('creates a fresh state file with default fields', () => {
    const fixedNow = new Date('2026-05-09T04:00:00.000Z');
    const exit = run(['wiki', '--sha', 'HEAD'], {
      cwd: sandbox.root,
      now: () => fixedNow,
    });
    expect(exit).toBe(0);

    const target = automationStatePath(sandbox.root, 'wiki');
    expect(existsSync(target)).toBe(true);

    const parsed = JSON.parse(readFileSync(target, 'utf8')) as Record<
      string,
      unknown
    >;
    expect(parsed).toEqual({
      cost_overage: false,
      last_run_at: '2026-05-09T04:00:00.000Z',
      last_run_cost: 0,
      last_run_sha: sandbox.headSha,
      last_run_trigger: 'cron',
      skip_count: 0,
      version: 1,
    });
  });

  it('refuses when the state file already exists', () => {
    const target = automationStatePath(sandbox.root, 'wiki');
    writeFileSync(target, '{}', 'utf8');

    const exit = run(['wiki', '--sha', sandbox.headSha], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_already_exists');
  });

  it('refuses unknown tool', () => {
    const exit = run(['nope', '--sha', sandbox.headSha], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('unknown tool');
  });

  it('rejects when --sha is missing', () => {
    const exit = run(['wiki'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('--sha');
  });

  it('rejects when --sha is unresolvable', () => {
    const exit = run(['wiki', '--sha', 'not-a-real-ref'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('sha_unresolvable');
  });

  it('honors --at as the timestamp', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--at', '2026-04-01T00:00:00Z'],
      {
        cwd: sandbox.root,
      }
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(
      readFileSync(automationStatePath(sandbox.root, 'wiki'), 'utf8')
    ) as Record<string, unknown>;
    expect(parsed.last_run_at).toBe('2026-04-01T00:00:00Z');
  });

  it('rejects a malformed --at and does not write the state file', () => {
    const exit = run(['wiki', '--sha', sandbox.headSha, '--at', 'not-a-date'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('state_malformed');
    expect(existsSync(automationStatePath(sandbox.root, 'wiki'))).toBe(false);
  });
});
