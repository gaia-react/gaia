import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {EXIT_CODES} from '../../exit.js';
import {run} from '../enable-dependabot-security.js';
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

describe('setup-ci enable-dependabot-security', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-enable-dependabot-security-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('happy path records the four argv lists in order and reports success', async () => {
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', '', '', '{"enabled":true,"paused":false}'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(EXIT_CODES.OK);

    const recorded = readRecordedArgv(sandbox);
    expect(recorded).toEqual([
      ['api', '-X', 'PUT', 'repos/foo/bar/vulnerability-alerts'],
      ['api', '-X', 'PUT', 'repos/foo/bar/automated-security-fixes'],
      ['api', 'repos/foo/bar/vulnerability-alerts'],
      ['api', 'repos/foo/bar/automated-security-fixes'],
    ]);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed).toEqual({
      alerts_enabled: true,
      paused: false,
      security_updates_enabled: true,
    });
  });

  test('reports paused: true when the API says so', async () => {
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', '', '', '{"enabled":true,"paused":true}'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(EXIT_CODES.OK);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.paused).toBe(true);
  });

  test('a failure at enable_alerts stops further calls', async () => {
    const handle = sandbox.installGhShim({exitCodeQueue: [1]});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const recorded = readRecordedArgv(sandbox);
    expect(recorded).toHaveLength(1);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.step).toBe('enable_alerts');
    expect(parsed.error).toBe('gh_api_error');
    expect(parsed.alerts_enabled).toBeNull();
    expect(parsed.security_updates_enabled).toBeNull();
  });

  test('a failure at enable_security_updates stops further calls', async () => {
    const handle = sandbox.installGhShim({exitCodeQueue: [0, 1]});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const recorded = readRecordedArgv(sandbox);
    expect(recorded).toHaveLength(2);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.step).toBe('enable_security_updates');
  });

  test('a failure at verify_alerts stops further calls', async () => {
    const handle = sandbox.installGhShim({exitCodeQueue: [0, 0, 1]});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const recorded = readRecordedArgv(sandbox);
    expect(recorded).toHaveLength(3);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.step).toBe('verify_alerts');
    expect(parsed.alerts_enabled).toBe(false);
  });

  test('enabled: false on the verify payload fails with verify_security_updates', async () => {
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', '', '', '{"enabled":false,"paused":false}'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const recorded = readRecordedArgv(sandbox);
    expect(recorded).toHaveLength(4);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.step).toBe('verify_security_updates');
    expect(parsed.alerts_enabled).toBe(true);
    expect(parsed.security_updates_enabled).toBe(false);
  });

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
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 0, 0, 0],
      stdoutQueue: ['', '', '', '{"enabled":true,"paused":false}'],
    });
    restore = handle.restore;

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
