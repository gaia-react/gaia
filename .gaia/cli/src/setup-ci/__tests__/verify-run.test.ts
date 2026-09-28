import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {pickDispatchedRun, run} from '../verify-run.js';
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

// A `gh run list --json databaseId,createdAt` page with one entry, timed
// relative to the moment the test builds it rather than a fixed date, so
// "created after the trigger" (the default +60s) and "created well before
// it" (a large negative offset) stay true no matter when the suite runs.
const runList = (id: number | string = 12_345, offsetMs = 60_000): string =>
  JSON.stringify([
    {createdAt: new Date(Date.now() + offsetMs).toISOString(), databaseId: id},
  ]);

const STALE_OFFSET_MS = -600_000;

// Step 0 of every run resolves the default branch via `gh repo view`.
const repoViewPayload = JSON.stringify({
  defaultBranchRef: {name: 'main'},
});

describe('pickDispatchedRun', () => {
  test('returns the oldest entry created at or after notBeforeMs', () => {
    const now = Date.now();
    const entries = [
      {createdAt: new Date(now + 120_000).toISOString(), databaseId: 333},
      {createdAt: new Date(now + 60_000).toISOString(), databaseId: 222},
      {
        createdAt: new Date(now + STALE_OFFSET_MS).toISOString(),
        databaseId: 111,
      },
    ];

    expect(pickDispatchedRun(entries, now - 5000)).toBe('222');
  });

  test('skips entries with a missing or unparseable createdAt', () => {
    const now = Date.now();
    const entries = [
      {databaseId: 1},
      {createdAt: 'not-a-date', databaseId: 2},
      {createdAt: new Date(now + 60_000).toISOString(), databaseId: 3},
    ];

    expect(pickDispatchedRun(entries, now - 5000)).toBe('3');
  });

  test('returns null when nothing qualifies', () => {
    const now = Date.now();
    const entries = [
      {createdAt: new Date(now + STALE_OFFSET_MS).toISOString(), databaseId: 1},
    ];

    expect(pickDispatchedRun(entries, now - 5000)).toBeNull();
  });
});

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

  test('returns verified: true on completed/success', async () => {
    // Sequence: repo view, workflow run, run list, run view (success).
    const handle = sandbox.installGhShim({
      stdoutQueue: [repoViewPayload, '', runList(), completedSuccess],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.verified).toBe(true);
    expect(parsed.conclusion).toBe('success');
    expect(parsed.run_id).toBe('12345');
  });

  test('returns verified: false on completed/failure', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [repoViewPayload, '', runList(), completedFailure],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.verified).toBe(false);
    expect(parsed.conclusion).toBe('failure');
  });

  test('polls until completed when status starts in_progress', async () => {
    // 6 calls: repo view, workflow run, run list, view in_progress,
    // view in_progress, view completed.
    const handle = sandbox.installGhShim({
      stdoutQueue: [
        repoViewPayload,
        '',
        runList(),
        inProgress,
        inProgress,
        completedSuccess,
      ],
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

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.verified).toBe(true);

    // Three view calls were made.
    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    const viewCalls = recorded.filter(
      (args) => args[0] === 'run' && args[1] === 'view'
    );
    expect(viewCalls).toHaveLength(3);
  });

  test('returns conclusion: polling_timeout on hard timeout', async () => {
    // Endless in_progress responses -> the handler should hit the
    // timeout and emit polling_timeout.
    const queue: string[] = [repoViewPayload, '', runList()];

    for (let index = 0; index < 50; index += 1) queue.push(inProgress);

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

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.verified).toBe(false);
    expect(parsed.conclusion).toBe('polling_timeout');
  });

  test('exits non-zero when gh workflow run fails', async () => {
    // Step 0 (repo view) succeeds; step 1 (workflow run) fails.
    const handle = sandbox.installGhShim({
      exitCodeQueue: [0, 1],
      stdoutQueue: [repoViewPayload, ''],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('workflow_run_failed');
  });

  test('exits non-zero when gh repo view fails', async () => {
    const handle = sandbox.installGhShim({exitCode: 1});
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('default_branch_lookup_failed');
  });

  test('dispatches against a non-main default branch', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [
        JSON.stringify({defaultBranchRef: {name: 'trunk'}}),
        '',
        runList(),
        completedSuccess,
      ],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    const dispatch = recorded.find(
      (args) => args[0] === 'workflow' && args[1] === 'run'
    );
    expect(dispatch).toContain('--ref');
    expect(dispatch?.[dispatch.indexOf('--ref') + 1]).toBe('trunk');
  });

  test('run list argv requests workflow_dispatch runs, limit 20', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [repoViewPayload, '', runList(), completedSuccess],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    const list = recorded.find(
      (args) => args[0] === 'run' && args[1] === 'list'
    );
    expect(list).toContain('--event');
    expect(list?.[list.indexOf('--event') + 1]).toBe('workflow_dispatch');
    expect(list).toContain('--limit');
    expect(list?.[list.indexOf('--limit') + 1]).toBe('20');
  });

  test('keeps polling gh run list until a run created after the trigger appears', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [
        repoViewPayload,
        '',
        runList(111, STALE_OFFSET_MS),
        runList(222),
        completedSuccess,
      ],
    });
    restore = handle.restore;

    const exit = await run(
      [
        '.github/workflows/gaia-ci-wiki.yml',
        '--json',
        '--poll-interval-ms',
        '5',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.run_id).toBe('222');

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    const listCalls = recorded.filter(
      (args) => args[0] === 'run' && args[1] === 'list'
    );
    expect(listCalls).toHaveLength(2);
  });

  test('exits with run_not_found when every listed run predates the trigger', async () => {
    const queue: string[] = [repoViewPayload, ''];

    for (let index = 0; index < 15; index += 1) {
      queue.push(runList(111, STALE_OFFSET_MS));
    }

    const handle = sandbox.installGhShim({stdoutQueue: queue});
    restore = handle.restore;

    const exit = await run(
      [
        '.github/workflows/gaia-ci-wiki.yml',
        '--json',
        '--poll-interval-ms',
        '5',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('run_not_found');
    expect(stdio.out.join('')).toBe('');

    const recorded = JSON.parse(
      readFileSync(sandbox.ghArgvPath, 'utf8')
    ) as string[][];
    const listCalls = recorded.filter(
      (args) => args[0] === 'run' && args[1] === 'list'
    );
    expect(listCalls).toHaveLength(15);
    const viewCalls = recorded.filter(
      (args) => args[0] === 'run' && args[1] === 'view'
    );
    expect(viewCalls).toHaveLength(0);
  });

  test('treats an empty gh run list page as not-yet-listed, not an error', async () => {
    const queue: string[] = [repoViewPayload, ''];

    for (let index = 0; index < 15; index += 1) queue.push('[]');

    const handle = sandbox.installGhShim({stdoutQueue: queue});
    restore = handle.restore;

    const exit = await run(
      [
        '.github/workflows/gaia-ci-wiki.yml',
        '--json',
        '--poll-interval-ms',
        '5',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);

    const error = JSON.parse(stdio.err.join('').trim()) as {code: string};
    expect(error.code).toBe('run_not_found');
  });

  test('exits non-zero with run_list_malformed when gh run list returns non-JSON', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [repoViewPayload, '', 'not json'],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('run_list_malformed');
  });

  test('exits non-zero with run_list_malformed when gh run list returns a non-array', async () => {
    const handle = sandbox.installGhShim({
      stdoutQueue: [repoViewPayload, '', '{}'],
    });
    restore = handle.restore;

    const exit = await run(['.github/workflows/gaia-ci-wiki.yml', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('run_list_malformed');
  });

  test('rejects --timeout-seconds with trailing garbage', async () => {
    const exit = await run(
      ['.github/workflows/foo.yml', '--timeout-seconds', '30abc'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('invalid_arguments');
  });

  test('exits non-zero when --timeout-seconds is invalid', async () => {
    const exit = await run(
      ['.github/workflows/foo.yml', '--timeout-seconds', '0'],
      {cwd: sandbox.root}
    );
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('invalid_arguments');
  });

  test('exits non-zero when workflow file argument is missing', async () => {
    const exit = await run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('missing_required_arg');
  });

  test('--help exits 0', async () => {
    const exit = await run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
