import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import {run as runCronDecide} from '../cron-decide.js';
import {setupSandbox, VALID_BASE_CONFIG} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

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

const decisionFromStdout = (
  out: string
): {
  decision: string;
  reason: string;
  skip_log_line: null | string;
} =>
  JSON.parse(out) as {
    decision: string;
    reason: string;
    skip_log_line: null | string;
  };

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

  test('exits non-zero with config_missing when there is no config', () => {
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('config_missing');
  });

  test('skips with reason tool_off when wiki.mode is "off"', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, wiki: {mode: 'off'}});
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
    expect(decision.skip_log_line).toBe('tool mode is off; skipping');
  });

  test('runs with reason enabled when wiki is configured (mode != off)', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('enabled');
    expect(decision.skip_log_line).toBeNull();
  });

  test('never suppresses on cost overage; a configured wiki tool always runs (reason=enabled)', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    // A stale state file with cost_overage=true once forced a skip. The
    // state layer is gone: cron-decide no longer reads any state file, so
    // even a present cost_overage blob cannot suppress an enabled wiki run.
    writeFileSync(
      path.join(sandbox.root, '.gaia', 'automation.state-wiki.json'),
      JSON.stringify({
        cost_overage: true,
        last_run_at: '2026-05-01T00:00:00Z',
        last_run_sha: sandbox.headSha,
        version: 1,
      }),
      'utf8'
    );

    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('run');
    expect(decision.reason).toBe('enabled');
    expect(decision.skip_log_line).toBeNull();
  });

  test('non-wiki tools return tool_off-shaped placeholder', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = runCronDecide(['update-deps', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
  });

  test('non-wiki tool with mode != off still returns the placeholder', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      stale_branches: {mode: 'ci', schedule: 'weekly'},
    });
    const exit = runCronDecide(['stale-branches', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    const decision = decisionFromStdout(stdio.outputs.join(''));
    expect(decision.decision).toBe('skip');
    expect(decision.reason).toBe('tool_off');
    expect(decision.skip_log_line).toContain('cron-decide not yet implemented');
  });

  test('no adopter cron turns red when isolation_policy is absent (UAT-002)', () => {
    sandbox.writeConfig(VALID_BASE_CONFIG);
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);
  });

  test('no adopter cron turns red when isolation_policy is a typo or future value (UAT-013)', () => {
    // `isolation_policy` is a permissive `z.string()` in `AutomationConfig`,
    // so a bogus value needs no cast: it is already a valid string.
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      isolation_policy: 'bogus',
    });
    const exit = runCronDecide(['wiki', '--json'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);
  });
});
