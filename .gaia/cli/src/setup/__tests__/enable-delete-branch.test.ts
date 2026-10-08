import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {run} from '../enable-delete-branch.js';
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

describe('setup enable-delete-branch', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-enable-delete-branch-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('PATCHes delete_branch_on_merge=true on success', async () => {
    const handle = sandbox.installGhShim({exitCode: 0});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    expect(recorded[0]).toEqual([
      'api',
      '-X',
      'PATCH',
      'repos/foo/bar',
      '-f',
      'delete_branch_on_merge=true',
    ]);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.applied).toBe(true);
  });

  test('returns applied: false with error on gh failure', async () => {
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(['--owner', 'foo', '--repo', 'bar'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.applied).toBe(false);
    expect(parsed.error).toBe('gh_api_error');
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

  test('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
