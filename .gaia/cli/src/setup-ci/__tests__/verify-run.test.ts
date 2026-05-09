import {readFileSync} from 'node:fs';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../verify-run.js';
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

const completedSuccess = JSON.stringify({
  conclusion: 'success',
  status: 'completed',
  url: 'https://github.com/foo/bar/actions/runs/12345',
});

const completedFailure = JSON.stringify({
  conclusion: 'failure',
  status: 'completed',
  url: 'https://github.com/foo/bar/actions/runs/12345',
});

const inProgress = JSON.stringify({
  conclusion: null,
  status: 'in_progress',
  url: 'https://github.com/foo/bar/actions/runs/12345',
});

const runListPayload = JSON.stringify([
  {createdAt: '2026-05-09T05:00:00.000Z', databaseId: 12_345},
]);

describe('setup-ci verify-run', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let restore: (() => void) | undefined;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-verify-run-');
    stdio = captureStdio();
  });

  afterEach(() => {
    restore?.();
    restore = undefined;
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('returns verified: true on completed/success', async () => {
    // Sequence: workflow run, run list, run view (completed success).
    const handle = sandbox.installGhShim({
      stdoutQueue: ['', runListPayload, completedSuccess],
    });
    restore = handle.restore;

    const exit = await run(
      ['.github/workflows/gaia-ci-wiki.yml', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.verified).toBe(true);
    expect(parsed.conclusion).toBe('success');
    expect(parsed.run_id).toBe('12345');
  });

  it('returns verified: false on completed/failure', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: ['', runListPayload, completedFailure],
    });
    restore = handle.restore;

    const exit = await run(
      ['.github/workflows/gaia-ci-wiki.yml', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.verified).toBe(false);
    expect(parsed.conclusion).toBe('failure');
  });

  it('polls until completed when status starts in_progress', async () => {
    // 5 calls: workflow run, run list, view in_progress, view in_progress, view completed.
    const handle = sandbox.installGhShim({
      stdoutQueue: ['', runListPayload, inProgress, inProgress, completedSuccess],
    });
    restore = handle.restore;

    const exit = await run(
      [
        '.github/workflows/gaia-ci-wiki.yml',
        '--json',
        '--poll-interval-ms',
        '5',
        '--timeout-seconds',
        '30',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.verified).toBe(true);

    // Three view calls were made.
    const recorded = JSON.parse(readFileSync(sandbox.ghArgvPath, 'utf8')) as string[][];
    const viewCalls = recorded.filter(
      (args) => args[0] === 'run' && args[1] === 'view'
    );
    expect(viewCalls.length).toBe(3);
  });

  it('returns conclusion: polling_timeout on hard timeout', async () => {
    // Endless in_progress responses -> the handler should hit the
    // timeout and emit polling_timeout.
    const queue: string[] = ['', runListPayload];

    for (let i = 0; i < 50; i += 1) queue.push(inProgress);

    const handle = sandbox.installGhShim({stdoutQueue: queue});
    restore = handle.restore;

    const exit = await run(
      [
        '.github/workflows/gaia-ci-wiki.yml',
        '--json',
        '--poll-interval-ms',
        '5',
        '--timeout-seconds',
        '1',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;
    expect(parsed.verified).toBe(false);
    expect(parsed.conclusion).toBe('polling_timeout');
  });

  it('exits non-zero when gh workflow run fails', async () => {
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(
      ['.github/workflows/gaia-ci-wiki.yml', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('workflow_run_failed');
  });

  it('exits non-zero when gh run list returns no runs', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: ['', '[]'],
    });
    restore = handle.restore;

    const exit = await run(
      ['.github/workflows/gaia-ci-wiki.yml', '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('run_list_empty');
  });

  it('exits non-zero when --timeout-seconds is invalid', async () => {
    const exit = await run(
      ['.github/workflows/foo.yml', '--timeout-seconds', '0'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('invalid_arguments');
  });

  it('exits non-zero when workflow file argument is missing', async () => {
    const exit = await run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  it('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
