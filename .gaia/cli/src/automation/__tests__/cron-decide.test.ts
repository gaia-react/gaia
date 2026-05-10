import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {automationStatePath} from '../paths.js';
import {run as runCronDecide} from '../cron-decide.js';
import {run as runRecordRun} from '../record-run.js';
import {run as runRecordOverage} from '../record-overage.js';
import {run as runClearOverage} from '../clear-overage.js';
import {VALID_BASE_CONFIG, setupSandbox, type Sandbox} from './sandbox.js';

const captureStdio = () => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  });
  const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
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

const decisionFromStdout = (out: string): {
  decision: string;
  reason: string;
  skip_log_line: string | null;
} => JSON.parse(out) as {decision: string; reason: string; skip_log_line: string | null};

const validState = (sha: string, overrides: Partial<AutomationStateFile> = {}): AutomationStateFile => ({
  cost_overage: false,
  last_run_at: '2026-05-01T00:00:00Z',
  last_run_cost: 0,
  last_run_sha: sha,
  last_run_trigger: 'cron',
  skip_count: 0,
  version: 1,
  ...overrides,
});

describe('automation cron-decide', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox('gaia-automation-cron-decide-');
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('exits non-zero with config_missing when there is no config', () => {
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('config_missing');
  });

  it('skips with reason tool_off when wiki.mode is "off"', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, wiki: {mode: 'off'}});
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
    expect(decision.skip_log_line).toBe('tool mode is off; skipping');
  });

  it('runs with reason first_run when state file is missing', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('first_run');
    expect(decision.skip_log_line).toBeNull();
  });

  it('skips with reason cost_overage when state.cost_overage is true', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState('wiki', validState(sandbox.headSha, {cost_overage: true}));

    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('cost_overage');
    expect(decision.skip_log_line).toBe('cost overage; suppressed');
  });

  it('runs with reason ceiling_14d when last_run_at is older than 14 days', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {last_run_at: '2026-04-01T00:00:00Z'})
    );

    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-01T00:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('ceiling_14d');
  });

  it('runs with reason skip_safety_5 when skip_count > 5', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {
        last_run_at: '2026-05-08T00:00:00Z',
        skip_count: 6,
      })
    );

    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-09T00:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('skip_safety_5');
  });

  it('skips with reason floor_24h when last_run_at < 24h ago', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {last_run_at: '2026-05-09T00:00:00Z'})
    );

    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-09T12:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('floor_24h');
    expect(decision.skip_log_line).toBe('within 24h floor; skipping');
  });

  it('runs with reason app_changed when commits to app/** since last_run_sha', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {last_run_at: '2026-05-01T00:00:00Z'})
    );
    sandbox.commitFile('app/foo.ts', 'export const x = 1;\n');

    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-05T00:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('app_changed');
  });

  it('skips with reason no_app_change when nothing in app/** since last_run_sha — UAT-001', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {last_run_at: '2026-05-01T00:00:00Z'})
    );
    // Commit OUTSIDE app/**
    sandbox.commitFile('docs/CHANGELOG.md', 'changes\n');

    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-05T00:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('no_app_change');
    expect(decision.skip_log_line).toBe(
      `skipped — no app/** changes since ${sandbox.headSha.slice(0, 7)}`
    );
  });

  it('UAT-002: 15-day-old state forces a run regardless of app changes', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    sandbox.writeState(
      'wiki',
      validState(sandbox.headSha, {last_run_at: '2026-04-20T00:00:00Z'})
    );
    // No app/** changes — should still run because of ceiling.
    const exit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-09T00:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('ceiling_14d');
  });

  it('UAT-005: after record-run --trigger force, next cron-decide returns floor_24h skip', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);

    const recordExit = runRecordRun(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'force', '--cost', '0'],
      {cwd: sandbox.root, now: () => new Date('2026-05-09T04:00:00Z')}
    );
    expect(recordExit).toBe(0);

    const cronExit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-09T05:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(cronExit).toBe(0);

    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('floor_24h');
    expect(decision.skip_log_line).toBe('within 24h floor; skipping');

    const stateFile = JSON.parse(
      readFileSync(automationStatePath(sandbox.root, 'wiki'), 'utf8')
    ) as Record<string, unknown>;
    expect(stateFile.last_run_trigger).toBe('force');
    expect(stateFile.skip_count).toBe(0);
  });

  it('UAT-018: record-overage then cron-decide returns cost_overage skip; clear-overage restores natural decision', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    runRecordRun(
      ['wiki', '--sha', sandbox.headSha, '--trigger', 'cron', '--cost', '0'],
      {cwd: sandbox.root, now: () => new Date('2026-05-09T04:00:00Z')}
    );

    const overageExit = runRecordOverage(['wiki', '--cost', '6.50'], {
      cwd: sandbox.root,
    });
    expect(overageExit).toBe(0);

    stdio.outputs.length = 0;
    const cronExit = runCronDecide(
      ['wiki', '--json', '--now', '2026-05-09T05:00:00Z'],
      {cwd: sandbox.root}
    );
    expect(cronExit).toBe(0);
    let decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.reason).toBe('cost_overage');

    const clearExit = runClearOverage(['wiki'], {cwd: sandbox.root});
    expect(clearExit).toBe(0);

    stdio.outputs.length = 0;
    runCronDecide(['wiki', '--json', '--now', '2026-05-09T05:00:00Z'], {
      cwd: sandbox.root,
    });
    decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.reason).toBe('floor_24h');
  });

  it('non-wiki tools return tool_off-shaped placeholder', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = runCronDecide(['update-deps', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
  });

  it('non-wiki tool with mode != off still returns the placeholder', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      stale_branches: {mode: 'ci', schedule: 'weekly'},
    });
    const exit = runCronDecide(['stale-branches', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
    expect(decision.skip_log_line).toContain('cron-decide not yet implemented');
  });
});
