import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {EXIT_CODES} from '../../exit.js';
import {run} from '../configure-dependabot-alerts.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readRecordedArgv = (sandbox: Sandbox): string[][] =>
  JSON.parse(readFileSync(sandbox.ghArgvPath, 'utf8')) as string[][];

const MANUAL_COMMANDS = [
  'gh api -X PUT repos/foo/bar/vulnerability-alerts',
  'gh api -X DELETE repos/foo/bar/automated-security-fixes',
];

const ENABLE_ALERTS = [
  'api',
  '-X',
  'PUT',
  'repos/foo/bar/vulnerability-alerts',
];
const READ_FIXES = ['api', 'repos/foo/bar/automated-security-fixes'];
const DISABLE_FIXES = [
  'api',
  '-X',
  'DELETE',
  'repos/foo/bar/automated-security-fixes',
];
const VERIFY_ALERTS = ['api', 'repos/foo/bar/vulnerability-alerts'];

const FIXES_ON = '{"enabled":true,"paused":false}';
const FIXES_OFF = '{"enabled":false,"paused":false}';

type FailureCase = {
  alertsEnabled: boolean | null;
  calls: number;
  changed: string[];
  exitCodeQueue: number[];
  fixesEnabled: boolean | null;
  label: string;
  stdoutQueue: string[];
  step: string;
};

const FAILURE_CASES: FailureCase[] = [
  {
    alertsEnabled: null,
    calls: 1,
    changed: [],
    exitCodeQueue: [1],
    fixesEnabled: null,
    label: 'the alerts enable call fails',
    stdoutQueue: [],
    step: 'enable_alerts',
  },
  {
    alertsEnabled: null,
    calls: 2,
    changed: [],
    exitCodeQueue: [0, 0],
    fixesEnabled: null,
    label: 'the security fixes read is not JSON',
    stdoutQueue: ['', 'not json'],
    step: 'read_security_fixes',
  },
  {
    alertsEnabled: null,
    calls: 2,
    changed: [],
    exitCodeQueue: [0, 1],
    fixesEnabled: null,
    label: 'the security fixes read call fails',
    stdoutQueue: [],
    step: 'read_security_fixes',
  },
  {
    alertsEnabled: true,
    calls: 3,
    changed: [],
    exitCodeQueue: [0, 0, 1],
    fixesEnabled: true,
    label: 'an organization-enforced setting refuses the disable',
    stdoutQueue: ['', FIXES_ON],
    step: 'disable_security_fixes',
  },
  {
    alertsEnabled: false,
    calls: 4,
    changed: ['automated security fixes disabled'],
    exitCodeQueue: [0, 0, 0, 1],
    fixesEnabled: true,
    label: 'alerts read back as disabled',
    stdoutQueue: ['', FIXES_ON],
    step: 'verify_alerts',
  },
  {
    alertsEnabled: true,
    calls: 5,
    changed: ['automated security fixes disabled'],
    exitCodeQueue: [0, 0, 0, 0, 0],
    fixesEnabled: true,
    label: 'fixes still read back as enabled after the disable',
    stdoutQueue: ['', FIXES_ON, '', '', FIXES_ON],
    step: 'verify_security_fixes',
  },
];

describe('setup-ci configure-dependabot-alerts', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-configure-dependabot-alerts-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  const runWithShim = async (
    options: Parameters<Sandbox['installGhShim']>[0]
  ): Promise<number> => {
    restore = sandbox.installGhShim(options).restore;

    return run(['--owner', 'foo', '--repo', 'bar'], {cwd: sandbox.root});
  };

  const readOutput = (): Record<string, unknown> =>
    JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;

  test('turns automated security fixes off and verifies both settings', async () => {
    const exit = await runWithShim({
      exitCodeQueue: [0, 0, 0, 0, 0],
      stdoutQueue: ['', FIXES_ON, '', '', FIXES_OFF],
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(readRecordedArgv(sandbox)).toEqual([
      ENABLE_ALERTS,
      READ_FIXES,
      DISABLE_FIXES,
      VERIFY_ALERTS,
      READ_FIXES,
    ]);
    expect(readOutput()).toEqual({
      alerts_enabled: true,
      automated_security_fixes_enabled: false,
      changed: ['automated security fixes disabled'],
    });
  });

  test('sends no disable call and reports no change when fixes are already off', async () => {
    const exit = await runWithShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', FIXES_OFF, '', FIXES_OFF],
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(readRecordedArgv(sandbox)).toEqual([
      ENABLE_ALERTS,
      READ_FIXES,
      VERIFY_ALERTS,
      READ_FIXES,
    ]);
    expect(readOutput()).toEqual({
      alerts_enabled: true,
      automated_security_fixes_enabled: false,
      changed: [],
    });
  });

  test.each(FAILURE_CASES)(
    'refuses at the failing step when $label',
    async ({
      alertsEnabled,
      calls,
      changed,
      exitCodeQueue,
      fixesEnabled,
      stdoutQueue,
      step,
    }) => {
      const exit = await runWithShim({
        exitCodeQueue,
        stderrQueue: exitCodeQueue.map(() => 'ghp_secret'),
        stdoutQueue,
      });

      expect(exit).not.toBe(EXIT_CODES.OK);
      expect(readRecordedArgv(sandbox)).toHaveLength(calls);
      expect(readOutput()).toEqual({
        alerts_enabled: alertsEnabled,
        automated_security_fixes_enabled: fixesEnabled,
        changed,
        error: 'gh_api_error',
        manual_commands: MANUAL_COMMANDS,
        step,
      });
      expect(stdio.out.join('')).not.toContain('ghp_secret');
    }
  );

  test('exits non-zero when --owner missing', async () => {
    const exit = await run(['--repo', 'bar'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  test('rejects unknown flags', async () => {
    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--bogus'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('accepts --json without changing the output shape', async () => {
    restore = sandbox.installGhShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', FIXES_OFF, '', FIXES_OFF],
    }).restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(EXIT_CODES.OK);
  });

  test('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
