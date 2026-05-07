/**
 * Tests for `gaia wiki sync land`.
 *
 * Strategy: stand up a real (empty) git repo so `git rev-parse
 * --show-toplevel` resolves the sandbox root, then inject a fake
 * `CommandRunner` that returns canned `SpawnSyncReturns<string>` values
 * keyed off the argv. Each test asserts both the handler's exit code
 * and the exact sequence of git/gh invocations the fake observed —
 * proving the CLI shapes the call pipeline correctly without depending
 * on a real `gh` binary or remote.
 */
import {execFileSync, type SpawnSyncReturns} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './sync-land.js';
import type {CommandRunner} from './util/branch.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-sync-land-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});
  // A throwaway file the runner mock pretends git/gh saw.
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

type MockSpec = {
  argv: readonly string[];
  status?: number;
  stderr?: string;
  stdout?: string;
};

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (status: number, stderr: string): SpawnSyncReturns<string> => ({
  output: ['', '', stderr] as never,
  pid: 0,
  signal: null,
  status,
  stderr,
  stdout: '',
});

const matches = (spec: MockSpec, command: string, argv: readonly string[]): boolean => {
  const target = [command, ...spec.argv];
  const observed = [command, ...argv];

  if (target.length !== observed.length) return false;

  return target.every((token, index) => token === observed[index]);
};

const buildRunner = (
  scripted: Array<{argv: readonly string[]; result: SpawnSyncReturns<string>}>,
  recorded: RecordedCall[]
): CommandRunner => (command, args) => {
  recorded.push({args: [...args], command});
  const match = scripted.find((entry) =>
    matches({argv: entry.argv}, command, args)
  );

  if (match !== undefined) return match.result;

  // Default: success with empty stdout. Exception: `git status` should
  // return a deterministic empty workspace by default; tests override
  // that explicitly when they need non-empty status output.
  return okResult('');
};

describe('wiki sync land', () => {
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

  test('on a feature branch with only wiki changes — in-place commit, exit 0', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M wiki/log.md\n M wiki/concepts/Foo.md\n'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'),
        },
        {argv: ['add', 'wiki'], result: okResult('')},
        {
          argv: ['commit', '-m', 'wiki: sync through aaaaaaa'],
          result: okResult(''),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'sync-land: landed via in-place commit'
    );

    const gitVerbs = recorded.filter((entry) => entry.command === 'git');
    // Sequence: rev-parse abbrev, status, rev-parse HEAD, add, commit.
    expect(gitVerbs.length).toBeGreaterThanOrEqual(5);
    expect(gitVerbs.at(-2)).toMatchObject({
      args: ['add', 'wiki'],
      command: 'git',
    });
    expect(gitVerbs.at(-1)?.args.slice(0, 2)).toEqual(['commit', '-m']);
    // No gh calls on the in-place path.
    const ghVerbs = recorded.filter((entry) => entry.command === 'gh');
    expect(ghVerbs).toHaveLength(0);
  });

  test('on main without --branch-aware — exit 1 with branch-policy message', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M wiki/log.md\n'),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      'refusing to land directly on main'
    );
    // No add / commit / push / gh calls when refusing.
    expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
    expect(recorded.find((c) => c.command === 'gh')).toBeUndefined();
  });

  test('on main with --branch-aware — branch + commit + push + PR + auto-merge', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M wiki/log.md\n'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
        },
      ],
      recorded
    );

    const exit = run(['--branch-aware'], {
      cwd: sandbox.root,
      runner,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'sync-land: landed via branch-and-PR commit'
    );

    // Locate the call sequence and verify each verb in order.
    const verbsAfterRevParse = recorded.slice(
      recorded.findIndex((c) =>
        c.args[0] === 'rev-parse' && c.args[1] === 'HEAD'
      ) + 1
    );
    const expected = [
      ['git', 'checkout', '-b', 'wiki-sync/2026-05-07-bbbbbbb'],
      ['git', 'add', 'wiki'],
      ['git', 'commit', '-m', 'wiki: sync through bbbbbbb'],
      ['git', 'push', '-u', 'origin', 'wiki-sync/2026-05-07-bbbbbbb'],
      ['gh', 'pr', 'create'],
      ['gh', 'pr', 'merge', '--squash', '--auto'],
    ] as const;

    for (const [index, prefix] of expected.entries()) {
      const call = verbsAfterRevParse[index];
      expect(call).toBeDefined();
      const observed = [call?.command, ...(call?.args ?? [])];
      const slice = observed.slice(0, prefix.length);
      expect(slice).toEqual([...prefix]);
    }
  });

  test('protected-branch flow short-circuits on first failing step', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M wiki/log.md\n'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('cccccccccccccccccccccccccccccccccccccccc\n'),
        },
        {
          argv: ['push', '-u', 'origin', 'wiki-sync/2026-05-07-ccccccc'],
          result: failResult(128, 'remote: rejected'),
        },
      ],
      recorded
    );

    const exit = run(['--branch-aware'], {
      cwd: sandbox.root,
      runner,
      today: '2026-05-07',
    });
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('git push');
    expect(stdio.errors.join('')).toContain('remote: rejected');
    // gh pr create / gh pr merge MUST NOT have been called after push failure.
    const ghCalls = recorded.filter((c) => c.command === 'gh');
    expect(ghCalls).toHaveLength(0);
  });

  test('working tree with non-wiki changes — exit 1', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M app/foo.ts\n M wiki/log.md\n'),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      'working tree has non-wiki changes'
    );
    expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
  });

  test('empty working tree — exit 1', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(''),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('nothing to land');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox();
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--help prints usage and exits 0 without invoking git', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner([], recorded);

    const exit = run(['--help'], {cwd: sandbox.root, runner});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage:');
    expect(recorded).toHaveLength(0);
  });

  test('treats master the same as main', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('master\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M wiki/log.md\n'),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain(
      'refusing to land directly on main'
    );
  });
});
