import {execFileSync} from 'node:child_process';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../detect-remote.js';
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

describe('setup-ci detect-remote', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-detect-remote-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('returns parsed fields when origin is configured', () => {
    execFileSync(
      'git',
      ['remote', 'add', 'origin', 'git@github.com:foo/bar.git'],
      {cwd: sandbox.root}
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toBe(true);
    expect(parsed.host).toBe('github.com');
    expect(parsed.owner).toBe('foo');
    expect(parsed.repo).toBe('bar');
  });

  it('returns found: false when origin is missing', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toBe(false);
    expect(parsed.url).toBeNull();
    expect(parsed.host).toBeNull();
  });

  it('returns found: false when remote URL is unparseable', () => {
    execFileSync(
      'git',
      ['remote', 'add', 'origin', 'https://gitlab.com/foo/bar/baz.git'],
      {cwd: sandbox.root}
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.found).toBe(false);
    // The URL itself is preserved for diagnostics.
    expect(parsed.url).toBe('https://gitlab.com/foo/bar/baz.git');
  });

  it('emits a human report without --json', () => {
    execFileSync(
      'git',
      ['remote', 'add', 'origin', 'https://github.com/foo/bar'],
      {cwd: sandbox.root}
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('host: github.com');
  });

  it('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  it('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
