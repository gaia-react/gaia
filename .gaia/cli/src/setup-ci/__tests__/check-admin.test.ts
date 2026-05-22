import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../check-admin.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

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

describe('setup-ci check-admin', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-check-admin-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('returns admin: true, auth_status: ok when gh auth ok and api returns true', async () => {
    // First call: `gh auth status` (exits 0 with no stdout). Second
    // call: `gh api ...` returns "true\n".
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['', 'true\n'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(true);
    expect(parsed.auth_status).toBe('ok');

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    expect(recorded[0]).toEqual(['auth', 'status']);
    expect(recorded[1]).toEqual([
      'api',
      'repos/foo/bar',
      '--jq',
      '.permissions.admin',
    ]);
  });

  it('returns admin: false, auth_status: ok when api returns false', async () => {
    const handle = sandbox.installGhShim({
      exitCode: 0,
      stdoutQueue: ['', 'false\n'],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('ok');
  });

  it('returns admin: false, auth_status: unauthenticated when gh auth fails', async () => {
    // gh auth status fails -> exit code != 0.
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    // Critical contract: never false-positive admin.
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('unauthenticated');
  });

  it('returns admin: false, auth_status: api_error when api call fails', async () => {
    // First gh call (auth status) succeeds; second (api) fails.
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 1],
      stdoutQueue: ['', ''],
    });
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.admin).toBe(false);
    expect(parsed.auth_status).toBe('api_error');
  });

  it('exits non-zero when --owner missing', async () => {
    const exit = await run(['--repo', 'bar', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  it('rejects unknown flags', async () => {
    const exit = await run(['--owner', 'foo', '--repo', 'bar', '--bogus'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  it('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
