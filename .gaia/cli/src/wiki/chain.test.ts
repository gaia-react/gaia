import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia wiki chain <begin|commit|finish>`.
 *
 * Strategy mirrors `sync-land.test.ts`: stand up a real (empty) git repo so
 * `git rev-parse --show-toplevel` resolves the sandbox root, then inject a
 * fake `CommandRunner` that returns canned `SpawnSyncReturns<string>` values
 * keyed off argv. Each test asserts the handler's exit code and the exact
 * sequence of git/gh invocations the fake observed.
 */
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './chain.js';
import type {CommandRunner} from './util/branch.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-chain-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  writeFileSync(path.join(root, 'wiki', 'log.md'), '---\n---\n', 'utf8');

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
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

type RecordedCall = {
  args: string[];
  command: string;
};

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (
  status: number,
  stderr: string
): SpawnSyncReturns<string> => ({
  output: ['', '', stderr] as never,
  pid: 0,
  signal: null,
  status,
  stderr,
  stdout: '',
});

const matches = (
  argv: readonly string[],
  command: string,
  observed: readonly string[]
): boolean => {
  const target = [command, ...argv];
  const seen = [command, ...observed];

  return (
    target.length === seen.length &&
    target.every((token, index) => token === seen[index])
  );
};

const buildRunner =
  (
    scripted: {
      argv: readonly string[];
      result: SpawnSyncReturns<string>;
    }[],
    recorded: RecordedCall[]
  ): CommandRunner =>
  (command, args) => {
    recorded.push({args: [...args], command});
    const match = scripted.find((entry) => matches(entry.argv, command, args));

    if (match !== undefined) return match.result;

    return okResult('');
  };

const gitCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter((entry) => entry.command === 'git');

const ghCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter((entry) => entry.command === 'gh');

describe('wiki chain', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  describe('begin', () => {
    test('on a feature branch: no-op, exit 0, no branch cut', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
        ],
        recorded
      );

      const exit = run(['begin'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain begin: in-place on feature/x'
      );
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });

    test('on main without --branch-aware: exit 1, no branch cut', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('main\n'),
          },
        ],
        recorded
      );

      const exit = run(['begin'], {cwd: sandbox.root, runner});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain(
        'refusing to start a wiki chain on main'
      );
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });

    test('on main with --branch-aware: cuts wiki-sync/<date>-<sha>, exit 0', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('main\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
          },
        ],
        recorded
      );

      const exit = run(['begin', '--branch-aware'], {
        cwd: sandbox.root,
        runner,
        today: '2026-05-07',
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain begin: started wiki-sync/2026-05-07-bbbbbbb'
      );
      expect(gitCalls(recorded).at(-1)).toMatchObject({
        args: ['checkout', '-b', 'wiki-sync/2026-05-07-bbbbbbb'],
        command: 'git',
      });
    });

    test('treats master like main', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('master\n'),
          },
        ],
        recorded
      );

      const exit = run(['begin'], {cwd: sandbox.root, runner});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain(
        'refusing to start a wiki chain on main'
      );
    });

    test('rejects unknown flag', () => {
      sandbox = setupSandbox();
      const exit = run(['begin', '--bogus'], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('unknown flag');
    });
  });

  describe('commit', () => {
    test('with only wiki changes: add + commit, exit 0', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['status', '--porcelain=v1', '-uall'],
            result: okResult(' M wiki/log.md\n?? wiki/meta/lint-report.md\n'),
          },
        ],
        recorded
      );

      const exit = run(['commit', '--label', 'wiki: lint through abc1234'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain commit: wiki: lint through abc1234'
      );
      const verbs = gitCalls(recorded);
      expect(verbs.at(-2)).toMatchObject({
        args: ['add', 'wiki'],
        command: 'git',
      });
      expect(verbs.at(-1)).toMatchObject({
        args: ['commit', '-m', 'wiki: lint through abc1234'],
        command: 'git',
      });
      expect(ghCalls(recorded)).toHaveLength(0);
    });

    test('with no wiki changes: graceful no-op, exit 0', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['status', '--porcelain=v1', '-uall'],
            result: okResult(''),
          },
        ],
        recorded
      );

      const exit = run(['commit', '--label', 'wiki: consolidate'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain commit: nothing to commit'
      );
      expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
    });

    test('with non-wiki changes: exit 1, no commit', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['status', '--porcelain=v1', '-uall'],
            result: okResult(' M app/foo.ts\n M wiki/log.md\n'),
          },
        ],
        recorded
      );

      const exit = run(['commit', '--label', 'wiki: x'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('non-wiki changes');
      expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
    });

    test('missing --label: exit 1', () => {
      sandbox = setupSandbox();
      const exit = run(['commit'], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('--label is required');
    });

    test('commit failure unstages wiki and exits 2', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['status', '--porcelain=v1', '-uall'],
            result: okResult(' M wiki/log.md\n'),
          },
          {argv: ['add', 'wiki'], result: okResult('')},
          {
            argv: ['commit', '-m', 'wiki: x'],
            result: failResult(1, 'nothing to commit'),
          },
        ],
        recorded
      );

      const exit = run(['commit', '--label', 'wiki: x'], {
        cwd: sandbox.root,
        runner,
      });
      expect(exit).toBe(2);
      expect(gitCalls(recorded)).toContainEqual({
        args: ['reset', 'HEAD', '--', 'wiki'],
        command: 'git',
      });
    });
  });

  describe('finish', () => {
    test('on a non-chain branch: no-op, exit 0, no PR', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('feature/x\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'chain finish: in-place commits remain on feature/x'
      );
      expect(ghCalls(recorded)).toHaveLength(0);
      expect(recorded.find((c) => c.args[0] === 'push')).toBeUndefined();
    });

    test('on a chain branch, PR merges: push + PR + auto-merge, then wait + local cleanup', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki-sync/2026-05-07-bbbbbbb\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('3\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
          },
          {
            argv: [
              'pr',
              'view',
              'wiki-sync/2026-05-07-bbbbbbb',
              '--json',
              'state',
              '--jq',
              '.state',
            ],
            result: okResult('MERGED\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish', '--branch-aware'], {
        cwd: sandbox.root,
        runner,
        sleep: () => undefined,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'merged PR for wiki-sync/2026-05-07-bbbbbbb and cleaned up locally'
      );

      const ordered = recorded.map((c) => [c.command, ...c.args].join(' '));
      const pushIndex = ordered.findIndex((c) =>
        c.startsWith('git push -u origin wiki-sync/2026-05-07-bbbbbbb')
      );
      const prCreateIndex = ordered.findIndex((c) =>
        c.startsWith('gh pr create')
      );
      const prMergeIndex = ordered.indexOf(
        'gh pr merge --squash --auto --delete-branch'
      );
      const pollIndex = ordered.findIndex((c) =>
        c.startsWith('gh pr view wiki-sync/2026-05-07-bbbbbbb')
      );
      const checkoutBaseIndex = ordered.indexOf('git checkout main');
      const pullIndex = ordered.indexOf('git pull --ff-only origin main');
      const branchDeleteIndex = ordered.indexOf(
        'git branch -D wiki-sync/2026-05-07-bbbbbbb'
      );
      const pruneIndex = ordered.indexOf('git fetch --prune origin');
      expect(pushIndex).toBeGreaterThanOrEqual(0);
      expect(prCreateIndex).toBeGreaterThan(pushIndex);
      expect(prMergeIndex).toBeGreaterThan(prCreateIndex);
      expect(pollIndex).toBeGreaterThan(prMergeIndex);
      expect(checkoutBaseIndex).toBeGreaterThan(pollIndex);
      expect(pullIndex).toBeGreaterThan(checkoutBaseIndex);
      expect(branchDeleteIndex).toBeGreaterThan(pullIndex);
      expect(pruneIndex).toBeGreaterThan(branchDeleteIndex);
    });

    test('on a chain branch, merge does not land: auto-merge stays queued, cleanup deferred', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki-sync/2026-05-07-fffffff\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('2\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('ffffffffffffffffffffffffffffffffffffffff\n'),
          },
          {
            argv: [
              'pr',
              'view',
              'wiki-sync/2026-05-07-fffffff',
              '--json',
              'state',
              '--jq',
              '.state',
            ],
            result: okResult('OPEN\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish', '--branch-aware'], {
        cwd: sandbox.root,
        mergePollAttempts: 3,
        runner,
        sleep: () => undefined,
      });
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'auto-merge queued but not yet merged, local cleanup deferred'
      );

      // Polled the budget, then returned to base but deferred the local cleanup.
      const pollCalls = ghCalls(recorded).filter(
        (c) => c.args[0] === 'pr' && c.args[1] === 'view'
      );
      expect(pollCalls).toHaveLength(3);
      expect(gitCalls(recorded)).toContainEqual({
        args: ['checkout', 'main'],
        command: 'git',
      });
      expect(recorded.find((c) => c.args[0] === 'branch')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'pull')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'fetch')).toBeUndefined();
    });

    test('on a chain branch with no commits ahead: drop empty branch, no PR', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki-sync/2026-05-07-ccccccc\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('0\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'removed empty branch wiki-sync/2026-05-07-ccccccc'
      );
      expect(gitCalls(recorded)).toContainEqual({
        args: ['checkout', 'main'],
        command: 'git',
      });
      expect(gitCalls(recorded)).toContainEqual({
        args: ['branch', '-D', 'wiki-sync/2026-05-07-ccccccc'],
        command: 'git',
      });
      expect(ghCalls(recorded)).toHaveLength(0);
    });

    test('empty chain branch with a dirty tree: left in place, no delete', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki-sync/2026-05-07-eeeeeee\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('0\n'),
          },
          {
            argv: ['status', '--porcelain=v1', '-uall'],
            result: okResult(' M wiki/log.md\n'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain(
        'has uncommitted changes and no commits'
      );
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'branch')).toBeUndefined();
      expect(ghCalls(recorded)).toHaveLength(0);
    });

    test('push failure short-circuits before any gh call, exit 2', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner(
        [
          {
            argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
            result: okResult('wiki-sync/2026-05-07-ddddddd\n'),
          },
          {
            argv: ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
            result: okResult('origin/main\n'),
          },
          {
            argv: ['rev-list', '--count', 'main..HEAD'],
            result: okResult('2\n'),
          },
          {
            argv: ['rev-parse', 'HEAD'],
            result: okResult('dddddddddddddddddddddddddddddddddddddddd\n'),
          },
          {
            argv: ['push', '-u', 'origin', 'wiki-sync/2026-05-07-ddddddd'],
            result: failResult(128, 'remote: rejected'),
          },
        ],
        recorded
      );

      const exit = run(['finish'], {cwd: sandbox.root, runner});
      expect(exit).toBe(2);
      expect(stdio.errors.join('')).toContain('remote: rejected');
      expect(ghCalls(recorded)).toHaveLength(0);
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    });

    test('rejects unknown flag', () => {
      sandbox = setupSandbox();
      const exit = run(['finish', '--bogus'], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('unknown flag');
    });
  });

  describe('dispatch', () => {
    test('--help prints usage without invoking git', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = buildRunner([], recorded);

      const exit = run(['--help'], {cwd: sandbox.root, runner});
      expect(exit).toBe(0);
      expect(stdio.outputs.join('')).toContain('Usage:');
      expect(recorded).toHaveLength(0);
    });

    test('unknown action: exit 1', () => {
      sandbox = setupSandbox();
      const exit = run(['bogus'], {cwd: sandbox.root});
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('unknown wiki chain action');
    });
  });
});
