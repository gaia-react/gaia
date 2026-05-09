import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {automationStatePath} from '../paths.js';
import {run} from '../record-run.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const silenceStdio = () => {
  const stdoutSpy = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

  return {
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readWikiState = (sandbox: Sandbox): Record<string, unknown> =>
  JSON.parse(readFileSync(automationStatePath(sandbox.root, 'wiki'), 'utf8')) as Record<
    string,
    unknown
  >;

describe('automation record-run', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof silenceStdio>;

  beforeEach(() => {
    stdio = silenceStdio();
    sandbox = setupSandbox('gaia-automation-record-run-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('writes a fresh state with skip_count reset to 0', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'cron', '--cost', '0.42'],
      {cwd: sandbox.root, now: () => new Date('2026-05-09T04:00:00.000Z')}
    );
    expect(exit).toBe(0);

    const parsed = readWikiState(sandbox);
    expect(parsed).toEqual({
      cost_overage: false,
      last_run_at: '2026-05-09T04:00:00.000Z',
      last_run_cost: 0.42,
      last_run_sha: sandbox.headSha,
      last_run_trigger: 'cron',
      skip_count: 0,
      version: 1,
    });
  });

  it('sets cost_overage = true when cost > 5', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'cron', '--cost', '5.50'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    expect(readWikiState(sandbox).cost_overage).toBe(true);
  });

  it('sets cost_overage = false when cost == 5 (strict-greater-than)', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'cron', '--cost', '5.00'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    expect(readWikiState(sandbox).cost_overage).toBe(false);
  });

  it('records last_run_trigger=force', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'force', '--cost', '0'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    expect(readWikiState(sandbox).last_run_trigger).toBe('force');
  });

  it('rejects unknown trigger', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'rerun', '--cost', '0'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
  });

  it('rejects negative cost', () => {
    const exit = run(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'cron', '--cost', '-1'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
  });

  it('rejects bad sha (40-char regex)', () => {
    const exit = run(
      ['wiki', '--sha', 'short', '--trigger', 'cron', '--cost', '0'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
  });
});
