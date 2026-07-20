import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import type {MockInstance} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {RevertLedger} from '../../schemas/revert-ledger.js';
import {withRevertLedgerLock} from '../../schemas/revert-ledger.js';
import {checkSubject} from '../check-subject.js';
import {run} from '../revert.js';
import * as runProcess from '../util/run-process.js';
import type {ProcessResult} from '../util/run-process.js';

type RunFn = (
  args: readonly string[],
  options?: {cwd?: string; env?: NodeJS.ProcessEnv}
) => ProcessResult;

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
  writeLedger: (ledger: RevertLedger) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-ci-revert-'));
  // The handler calls resolveRepoRoot, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  const ledgerPath = path.join(
    root,
    '.gaia',
    'automation.state-revert-attempts.json'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath,
    root,
    writeLedger: (ledger) => {
      writeFileSync(ledgerPath, JSON.stringify(ledger), 'utf8');
    },
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

const ghViewMerged = JSON.stringify({
  baseRefName: 'main',
  headRefName: 'gaia-ci/wiki/2026-05-09',
  mergeCommit: {oid: '0123456789abcdef0123456789abcdef01234567'},
  title: 'wiki: nightly run',
});

const ghCreateUrl = 'https://github.com/owner/repo/pull/137\n';

// Hoisted to module scope (unicorn/consistent-function-scoping): it closes
// over no per-test state, only the module-level fixtures above.
const ghImpl: RunFn = (args) => {
  const [a, b] = args;

  if (a === 'pr' && b === 'view') {
    return {exitCode: 0, stderr: '', stdout: ghViewMerged};
  }

  if (a === 'pr' && b === 'create') {
    return {exitCode: 0, stderr: '', stdout: ghCreateUrl};
  }

  if (a === 'pr' && b === 'merge') {
    return {exitCode: 0, stderr: '', stdout: ''};
  }

  return {exitCode: 0, stderr: '', stdout: ''};
};

const gitRevertConflictImpl: RunFn = (args) => {
  if (args[0] === 'revert' && args[1] === '--no-edit') {
    return {exitCode: 1, stderr: 'CONFLICT (content)', stdout: ''};
  }

  return {exitCode: 0, stderr: '', stdout: ''};
};

const gitPushFailureImpl: RunFn = (args) => {
  if (args[0] === 'symbolic-ref') {
    return {exitCode: 0, stderr: '', stdout: 'main\n'};
  }

  if (args[0] === 'push') {
    return {exitCode: 1, stderr: 'remote rejected', stdout: ''};
  }

  return {exitCode: 0, stderr: '', stdout: ''};
};

const ghCreateWithBannerImpl: RunFn = (args) => {
  if (args[0] === 'pr' && args[1] === 'view') {
    return {exitCode: 0, stderr: '', stdout: ghViewMerged};
  }

  if (args[0] === 'pr' && args[1] === 'create') {
    return {
      exitCode: 0,
      stderr: '',
      stdout:
        'Creating pull request for ...\nhttps://github.com/owner/repo/pull/137\n',
    };
  }

  return {exitCode: 0, stderr: '', stdout: ''};
};

// Narrows a `withRevertLedgerLock` result without an `if` inside the test
// body (vitest/no-conditional-in-test forbids that); called from tests to
// get both the runtime check and the TS type narrowing.
function assertLocked<T>(
  result: {locked: false} | {locked: true; value: T}
): asserts result is {locked: true; value: T} {
  if (!result.locked) {
    throw new Error('expected the ledger lock to be acquired');
  }
}

describe('ci-revert', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;
  let ghSpy: MockInstance<typeof runProcess.runGh>;
  let gitSpy: MockInstance<typeof runProcess.runGit>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();

    ghSpy = vi.spyOn(runProcess, 'runGh').mockImplementation(ghImpl);
    gitSpy = vi
      .spyOn(runProcess, 'runGit')
      .mockReturnValue({exitCode: 0, stderr: '', stdout: ''});
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  describe('open', () => {
    // The revert PR's title becomes the subject on main after a squash, so it
    // has to satisfy the same grammar everything else reads. `Revert: ...`
    // does not: the type is anchored lowercase, so the capitalized form
    // reds the PR-title check on the automation that runs precisely when main
    // is already broken.
    test('emits a conventional-commit PR title', () => {
      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const createCall = ghSpy.mock.calls.find(
        ([args]) => args[0] === 'pr' && args[1] === 'create'
      );
      const createArgs = createCall?.[0] ?? [];
      const title = createArgs[createArgs.indexOf('--title') + 1] ?? '';

      expect(title).toBe('revert: wiki: nightly run');
      expect(checkSubject(title).ok).toBe(true);
    });

    test('opens the revert PR and writes the ledger', () => {
      const fixedNow = new Date('2026-05-09T05:00:00.000Z');
      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
        now: () => fixedNow,
      });
      expect(exit).toBe(0);

      const success = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(success.revert_pr).toBe(137);
      expect(success.original_pr).toBe(99);
      expect(success.revert_branch).toBe(
        'gaia-ci/revert/gaia-ci/wiki/2026-05-09-0123456'
      );

      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99']).toEqual({
        opened_at: '2026-05-09T05:00:00.000Z',
        original_pr: 99,
        revert_pr: 137,
        status: 'open',
      });

      // Verify the external commands were called in order. A
      // `symbolic-ref` probe runs between fetch and checkout to capture
      // the rollback target.
      const ghArgsList = ghSpy.mock.calls.map(
        (call: [readonly string[], unknown?]) => call[0]
      );
      const gitArgsList = gitSpy.mock.calls.map(
        (call: [readonly string[], unknown?]) => call[0]
      );

      expect(ghArgsList[0]?.slice(0, 3)).toEqual(['pr', 'view', '99']);
      expect(gitArgsList[0]).toEqual(['fetch', 'origin', 'main']);
      expect(gitArgsList[1]?.[0]).toBe('symbolic-ref');
      expect(gitArgsList[2]?.[0]).toBe('checkout');
      expect(gitArgsList[3]?.slice(0, 3)).toEqual([
        'revert',
        '--no-edit',
        '0123456789abcdef0123456789abcdef01234567',
      ]);
      expect(gitArgsList[4]).toEqual([
        'push',
        '-u',
        'origin',
        'gaia-ci/revert/gaia-ci/wiki/2026-05-09-0123456',
      ]);
      expect(ghArgsList[1]?.slice(0, 2)).toEqual(['pr', 'create']);
      expect(ghArgsList[2]).toEqual([
        'pr',
        'merge',
        '137',
        '--auto',
        '--squash',
      ]);
    });

    test('refuses with revert_already_opened when an entry exists', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      // Hard cap: zero gh / git invocations.
      expect(ghSpy.mock.calls).toHaveLength(0);
      expect(gitSpy.mock.calls).toHaveLength(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('revert_already_opened');
      expect(printed.existing_revert_pr).toBe(137);

      // Ledger byte-identical.
      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99'].status).toBe('open');
      expect(ledger.attempts['99'].revert_pr).toBe(137);
    });

    test('exits with pr_not_merged when mergeCommit is null', () => {
      const impl: RunFn = (args) => {
        if (args[0] === 'pr' && args[1] === 'view') {
          return {
            exitCode: 0,
            stderr: '',
            stdout: JSON.stringify({
              baseRefName: 'main',
              headRefName: 'gaia-ci/wiki',
              mergeCommit: null,
              title: 'open PR',
            }),
          };
        }

        return {exitCode: 0, stderr: '', stdout: ''};
      };
      ghSpy.mockImplementation(impl);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      // Only gh pr view was called; nothing else.
      expect(ghSpy.mock.calls).toHaveLength(1);
      expect(gitSpy.mock.calls).toHaveLength(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('pr_not_merged');

      // Ledger never written.
      expect(() => readFileSync(sandbox.ledgerPath, 'utf8')).toThrow(/ENOENT/);
    });

    test('rejects when --pr is missing', () => {
      const exit = run(['open', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--pr');
    });

    test('rejects when --label is missing', () => {
      const exit = run(['open', '--pr', '99', '--json'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--label');
    });

    test('emits revert_failed on git revert conflict', () => {
      gitSpy.mockImplementation(gitRevertConflictImpl);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('revert_failed');
      expect(printed.step).toBe('git_revert');
    });

    test('rolls back the local branch when git push fails', () => {
      gitSpy.mockImplementation(gitPushFailureImpl);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('revert_failed');
      expect(printed.step).toBe('git_push');

      // Rollback: checkout back to the prior branch and delete the
      // revert branch must both have run after the failed push.
      const gitArgsList = gitSpy.mock.calls.map(
        (call: [readonly string[], unknown?]) => call[0]
      );
      const checkoutBack = gitArgsList.find(
        (a: readonly string[]) =>
          a[0] === 'checkout' && a[1] === '--force' && a[2] === 'main'
      );
      const deleteBranch = gitArgsList.find(
        (a: readonly string[]) => a[0] === 'branch' && a[1] === '-D'
      );
      expect(checkoutBack).toBeDefined();
      expect(deleteBranch).toBeDefined();

      // The ledger must not be written on a failed push.
      expect(() => readFileSync(sandbox.ledgerPath, 'utf8')).toThrow(/ENOENT/);
    });

    test('refuses when the per-PR ledger lock is already held', () => {
      mkdirSync(`${sandbox.ledgerPath}.lock.pr-99`, {recursive: true});

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      // Hard cap: zero gh / git invocations while a revert is in flight.
      expect(ghSpy.mock.calls).toHaveLength(0);
      expect(gitSpy.mock.calls).toHaveLength(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('revert_lock_held');
    });

    test('proceeds when a lock for a different PR is held', () => {
      // A lock scoped to PR 137 must not block a revert open for PR 99.
      mkdirSync(`${sandbox.ledgerPath}.lock.pr-137`, {recursive: true});

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99'].revert_pr).toBe(137);
    });

    test('reclaims a stale per-PR lock and proceeds', () => {
      const lockDir = `${sandbox.ledgerPath}.lock.pr-99`;
      mkdirSync(lockDir, {recursive: true});
      // Backdate the lock dir's mtime well past the stale threshold
      // (5 min). 1 h ago is comfortably stale.
      const stale = new Date(Date.now() - 60 * 60_000);
      utimesSync(lockDir, stale, stale);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99'].revert_pr).toBe(137);
    });

    test('refuses when a fresh per-PR lock is held', () => {
      const lockDir = `${sandbox.ledgerPath}.lock.pr-99`;
      mkdirSync(lockDir, {recursive: true});
      // mtime within the threshold, a healthy concurrent revert.
      const fresh = new Date(Date.now() - 30_000);
      utimesSync(lockDir, fresh, fresh);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('revert_lock_held');
    });

    test('parses the new PR number even with a banner line in stdout', () => {
      ghSpy.mockImplementation(ghCreateWithBannerImpl);

      const exit = run(['open', '--pr', '99', '--label', 'gaia-ci', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99'].revert_pr).toBe(137);
    });
  });

  describe('mark-failed', () => {
    test('flips status to failed', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(['mark-failed', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      // mark-failed never invokes gh / git.
      expect(ghSpy.mock.calls).toHaveLength(0);
      expect(gitSpy.mock.calls).toHaveLength(0);

      const ledger = JSON.parse(
        readFileSync(sandbox.ledgerPath, 'utf8')
      ) as RevertLedger;
      expect(ledger.attempts['99'].status).toBe('failed');
      expect(ledger.attempts['99'].revert_pr).toBe(137);
    });

    test('exits non-zero on missing attempt', () => {
      const exit = run(['mark-failed', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).not.toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.error).toBe('no_revert_attempt');
    });

    test('rejects when --pr is missing', () => {
      const exit = run(['mark-failed'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('--pr');
    });
  });

  describe('is-cap-reached', () => {
    test('reports true for status: open', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'open',
          },
        },
        version: 1,
      });

      const exit = run(['is-cap-reached', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.cap_reached).toBe(true);
      expect(printed.status).toBe('open');
    });

    test('reports true for status: failed', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'failed',
          },
        },
        version: 1,
      });

      const exit = run(['is-cap-reached', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.cap_reached).toBe(true);
      expect(printed.status).toBe('failed');
    });

    test('reports false for status: merged', () => {
      sandbox.writeLedger({
        attempts: {
          '99': {
            opened_at: '2026-05-08T00:00:00Z',
            original_pr: 99,
            revert_pr: 137,
            status: 'merged',
          },
        },
        version: 1,
      });

      const exit = run(['is-cap-reached', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.cap_reached).toBe(false);
      expect(printed.status).toBe('merged');
    });

    test('reports false on missing entry', () => {
      const exit = run(['is-cap-reached', '--pr', '99', '--json'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const printed = JSON.parse(stdio.out.join('').trim()) as Record<
        string,
        unknown
      >;
      expect(printed.cap_reached).toBe(false);
      expect(printed.status).toBeNull();
    });
  });

  describe('help & dispatch', () => {
    test('prints help on no args', () => {
      const exit = run([], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.out.join('')).toContain('Usage: gaia ci-revert');
    });

    test('prints help on --help and exits 0', () => {
      const exit = run(['--help'], {cwd: sandbox.root});
      expect(exit).toBe(0);
      expect(stdio.out.join('')).toContain('Usage: gaia ci-revert');
    });

    test('exits non-zero on unknown subcommand', () => {
      const exit = run(['unknown'], {cwd: sandbox.root});
      expect(exit).not.toBe(0);
      expect(stdio.err.join('')).toContain('unknown');
    });
  });

  describe('withRevertLedgerLock', () => {
    test('propagates a non-EEXIST lock-acquire error', () => {
      // A read-only lock parent makes the lock-dir `mkdir` fail with
      // EACCES, a genuine error, not contention. It must propagate
      // rather than be swallowed into {locked: false}.
      const ledgerDir = path.join(sandbox.root, '.gaia');
      chmodSync(ledgerDir, 0o500);

      try {
        expect(() =>
          withRevertLedgerLock(sandbox.root, 99, () => 'never-runs')
        ).toThrow(/EACCES/);
      } finally {
        // Restore writability so the sandbox cleanup can remove it.
        chmodSync(ledgerDir, 0o700);
      }
    });

    test('does not serialize locks for different PRs', () => {
      const outer = withRevertLedgerLock(sandbox.root, 99, () =>
        // While PR 99's lock is held, a revert for PR 100 still acquires.
        withRevertLedgerLock(sandbox.root, 100, () => 'inner-ran')
      );

      expect(outer.locked).toBe(true);
      assertLocked(outer);

      expect(outer.value.locked).toBe(true);
      assertLocked(outer.value);

      expect(outer.value.value).toBe('inner-ran');
    });

    test('serializes locks for the same PR', () => {
      const outer = withRevertLedgerLock(sandbox.root, 99, () =>
        // A second open for the same PR while the first holds a fresh
        // lock is refused.
        withRevertLedgerLock(sandbox.root, 99, () => 'inner-ran')
      );

      expect(outer.locked).toBe(true);
      assertLocked(outer);

      expect(outer.value.locked).toBe(false);
    });

    test('reclaims a stale lock directory', () => {
      const lockDir = path.join(
        sandbox.root,
        '.gaia',
        'automation.state-revert-attempts.json.lock.pr-99'
      );
      mkdirSync(lockDir, {recursive: true});
      const stale = new Date(Date.now() - 60 * 60_000);
      utimesSync(lockDir, stale, stale);

      const result = withRevertLedgerLock(
        sandbox.root,
        99,
        () => 'critical-ran'
      );

      expect(result.locked).toBe(true);
      assertLocked(result);

      expect(result.value).toBe('critical-ran');

      // The lock dir is released on the happy path.
      expect(() => statSync(lockDir)).toThrow(/ENOENT/);
    });

    test('refuses when a fresh lock directory exists', () => {
      const lockDir = path.join(
        sandbox.root,
        '.gaia',
        'automation.state-revert-attempts.json.lock.pr-99'
      );
      mkdirSync(lockDir, {recursive: true});
      const fresh = new Date(Date.now() - 30_000);
      utimesSync(lockDir, fresh, fresh);

      const result = withRevertLedgerLock(sandbox.root, 99, () => 'never-runs');

      expect(result.locked).toBe(false);
      // The pre-existing fresh lock is left in place, not reclaimed.
      expect(() => statSync(lockDir)).not.toThrow();
    });
  });
});
