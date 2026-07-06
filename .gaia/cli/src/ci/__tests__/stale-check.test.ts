import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from '../stale-check.js';
import * as runProcess from '../util/run-process.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  // We don't need a real git repo for stale-check (it never calls
  // resolveRepoRoot), but a tmp cwd keeps the test hermetic.
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-stale-check-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = () => {
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

describe('ci-stale-check', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('emits decision: "skip" when gh returns one entry', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 0,
      stderr: '',
      stdout: JSON.stringify([
        {
          createdAt: '2026-05-09T03:00:00Z',
          headRefName: 'gaia-ci/wiki/2026-05-09',
          number: 42,
        },
      ]),
    });

    const exit = run(['--label', 'gaia-ci', '--base', 'main', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const lastCall = ghSpy.mock.calls.at(-1)?.[0] ?? [];
    expect(lastCall).toContain('--label');
    expect(lastCall).toContain('gaia-ci');
    expect(lastCall).toContain('--author');
    expect(lastCall).toContain('github-actions[bot]');
    expect(lastCall).toContain('--base');
    expect(lastCall).toContain('main');

    const printed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(printed.decision).toBe('skip');
    expect(printed.open_pr_number).toBe(42);
    expect(printed.open_pr_branch).toBe('gaia-ci/wiki/2026-05-09');
    expect(printed.skip_log_line).toBe(
      'open gaia-ci PR #42 exists; skipping run'
    );
  });

  test('emits decision: "proceed" when gh returns []', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 0,
      stderr: '',
      stdout: '[]',
    });

    const exit = run(['--label', 'gaia-ci', '--base', 'main', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const printed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(printed.decision).toBe('proceed');
    expect(printed.open_pr_number).toBeNull();
    expect(printed.open_pr_branch).toBeNull();
    expect(printed.skip_log_line).toBeNull();
  });

  test('exits non-zero with structured error when gh fails', () => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 4,
      stderr: 'gh: not authenticated',
      stdout: '',
    });

    const exit = run(['--label', 'gaia-ci', '--base', 'main', '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).not.toBe(0);

    const errors = stdio.err.join('');
    expect(errors).toContain('gh_invocation_failed');

    const printed = stdio.out.join('').trim();
    expect(printed).toContain('gh_invocation_failed');
  });

  test('passes both --label AND --author to gh pr list', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 0,
      stderr: '',
      stdout: '[]',
    });

    run(['--label', 'gaia-ci', '--base', 'main', '--json'], {
      cwd: sandbox.root,
    });

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    // Verbatim assertion: both predicates appear, exactly once each.
    expect(args.filter((a) => a === '--label').length).toBe(1);
    expect(args.filter((a) => a === '--author').length).toBe(1);
    // And the values immediately follow the flags.
    const labelIndex = args.indexOf('--label');
    const authorIndex = args.indexOf('--author');
    expect(args[labelIndex + 1]).toBe('gaia-ci');
    expect(args[authorIndex + 1]).toBe('github-actions[bot]');
  });

  test('honors a custom --author', () => {
    const ghSpy = vi.spyOn(runProcess, 'runGh').mockReturnValue({
      exitCode: 0,
      stderr: '',
      stdout: '[]',
    });

    run(
      [
        '--label',
        'gaia-ci',
        '--base',
        'main',
        '--author',
        'someone-else',
        '--json',
      ],
      {cwd: sandbox.root}
    );

    const args = ghSpy.mock.calls[0]?.[0] ?? [];
    const authorIndex = args.indexOf('--author');
    expect(args[authorIndex + 1]).toBe('someone-else');
  });

  test('rejects when --label is missing', () => {
    const exit = run(['--base', 'main', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('--label');
  });

  test('rejects when --base is missing', () => {
    const exit = run(['--label', 'gaia-ci', '--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('--base');
  });

  test('exits 0 with help on --help', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage: gaia ci-stale-check');
  });
});
