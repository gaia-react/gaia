/**
 * Strategy: stand up a real (empty) git repo so `git rev-parse
 * --show-toplevel` resolves the sandbox root, then inject a fake
 * `CommandRunner` that returns canned `SpawnSyncReturns<string>` values
 * keyed off the argv. Each test asserts both the handler's exit code
 * and the exact sequence of git/gh invocations the fake observed;
 * proving the CLI shapes the call pipeline correctly without depending
 * on a real `gh` binary or remote.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
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

type MockSpec = {
  argv: readonly string[];
  status?: number;
  stderr?: string;
  stdout?: string;
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
  spec: MockSpec,
  command: string,
  argv: readonly string[]
): boolean => {
  const target = [command, ...spec.argv];
  const observed = [command, ...argv];

  return (
    target.length === observed.length &&
    target.every((token, index) => token === observed[index])
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
    const match = scripted.find((entry) =>
      matches({argv: entry.argv}, command, args)
    );

    if (match !== undefined) return match.result;

    // Default: success with empty stdout. Exception: `git status` should
    // return a deterministic empty workspace by default; tests override
    // that explicitly when they need non-empty status output.
    return okResult('');
  };

const TALLY_SCRIPT = '.gaia/scripts/token-tally.sh';

const tallyCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter(
    (entry) => entry.command === 'bash' && entry.args[0] === TALLY_SCRIPT
  );

const landProtected = (cwd: string, runner: CommandRunner): number =>
  run(['--branch-aware'], {
    cwd,
    runner,
    sleep: () => undefined,
    today: '2026-05-07',
  });

const statusCalls = (recorded: RecordedCall[]): RecordedCall[] =>
  recorded.filter(
    (entry) =>
      entry.command === 'gh' &&
      entry.args[0] === 'api' &&
      entry.args.some((token) => token.includes('/statuses/'))
  );

const cachePathOf = (root: string): string =>
  path.join(root, '.gaia', 'local', 'cache', 'shared', 'update-check.json');

const seedCache = (root: string): void => {
  mkdirSync(path.dirname(cachePathOf(root)), {recursive: true});
  writeFileSync(
    cachePathOf(root),
    JSON.stringify({checkedAt: 1_700_000_000, wikiDriftCount: 31}),
    'utf8'
  );
};

const readCache = (root: string): Record<string, unknown> =>
  JSON.parse(readFileSync(cachePathOf(root), 'utf8')) as Record<
    string,
    unknown
  >;

const featureRunner = (recorded: RecordedCall[]): CommandRunner =>
  buildRunner(
    [
      {
        argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
        result: okResult('feature/x\n'),
      },
      {
        argv: ['status', '--porcelain=v1', '-z', '-uall'],
        result: okResult(' M wiki/log.md\0'),
      },
      {
        argv: ['rev-parse', 'HEAD'],
        result: okResult('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'),
      },
    ],
    recorded
  );

const mainRunner = (
  recorded: RecordedCall[],
  overrides: {
    argv: readonly string[];
    result: SpawnSyncReturns<string>;
  }[] = []
): CommandRunner =>
  buildRunner(
    [
      ...overrides,
      {
        argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
        result: okResult('main\n'),
      },
      {
        argv: ['status', '--porcelain=v1', '-z', '-uall'],
        result: okResult(' M wiki/log.md\0'),
      },
      {
        argv: ['rev-parse', 'HEAD'],
        result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
      },
      {
        argv: [
          'pr',
          'view',
          'wiki/sync-2026-05-07-bbbbbbb',
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

  test('on a feature branch with only wiki changes: in-place commit, exit 0', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0 M wiki/concepts/Foo.md\0'),
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

  test('on main without --branch-aware: exit 1 with branch-policy message', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
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

  test('on main with --branch-aware, PR merges: branch + commit + push + PR + stamp + auto-merge, then wait + cleanup', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: [
            'pr',
            'view',
            'wiki/sync-2026-05-07-bbbbbbb',
            '--json',
            'files,headRefOid,baseRefName',
          ],
          result: okResult(
            JSON.stringify({
              baseRefName: 'main',
              files: [{path: 'wiki/log.md'}],
              headRefOid: 'b'.repeat(40),
            })
          ),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
        },
        {
          argv: [
            'pr',
            'view',
            'wiki/sync-2026-05-07-bbbbbbb',
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

    const exit = run(['--branch-aware'], {
      cwd: sandbox.root,
      runner,
      sleep: () => undefined,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'sync-land: merged PR for wiki/sync-2026-05-07-bbbbbbb and cleaned up locally'
    );

    // Locate the call sequence and verify each verb in order.
    const verbsAfterRevParse = recorded.slice(
      recorded.findIndex(
        (c) => c.args[0] === 'rev-parse' && c.args[1] === 'HEAD'
      ) + 1
    );
    const expected = [
      ['git', 'checkout', '-b', 'wiki/sync-2026-05-07-bbbbbbb'],
      ['git', 'add', 'wiki'],
      ['git', 'commit', '-m', 'wiki: sync through bbbbbbb'],
      ['git', 'push', '-u', 'origin', 'wiki/sync-2026-05-07-bbbbbbb'],
      ['gh', 'pr', 'create'],
      [
        'gh',
        'pr',
        'view',
        'wiki/sync-2026-05-07-bbbbbbb',
        '--json',
        'files,headRefOid,baseRefName',
      ],
      ['git', 'rev-parse', 'HEAD'],
      ['git', 'fetch', 'origin', 'main'],
      ['bash', '.gaia/scripts/resolve-audit-members.sh'],
      [
        'gh',
        'api',
        '-X',
        'POST',
        `repos/{owner}/{repo}/statuses/${'b'.repeat(40)}`,
        '-f',
        'state=success',
        '-f',
        'context=GAIA-Audit',
        '-f',
        'description=skipped: out of scope',
      ],
      ['gh', 'pr', 'merge', '--squash', '--auto', '--delete-branch'],
      ['gh', 'pr', 'view', 'wiki/sync-2026-05-07-bbbbbbb'],
      ['git', 'checkout', '--end-of-options', 'main'],
      ['git', 'pull', '--ff-only', 'origin', 'main'],
      ['git', 'branch', '-D', '--', 'wiki/sync-2026-05-07-bbbbbbb'],
      ['git', 'fetch', '--prune', 'origin'],
    ] as const;

    const observed = verbsAfterRevParse.map((call) => [
      call.command,
      ...call.args,
    ]);

    for (const [index, prefix] of expected.entries()) {
      expect(observed[index]?.slice(0, prefix.length)).toEqual([...prefix]);
    }
  });

  test('protected-branch landing makes zero tally calls and writes no breadcrumb', () => {
    // `gaia wiki sync land` standalone (outside the `chain` command) never
    // emits a cost record and never writes the gh-artifact breadcrumb, even
    // on the path that opens its own PR: only `chain finish` emits for
    // `/gaia-wiki`, and no six-command surface writes a breadcrumb at all.
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
        },
        {
          argv: [
            'pr',
            'view',
            'wiki/sync-2026-05-07-bbbbbbb',
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

    const exit = run(['--branch-aware'], {
      cwd: sandbox.root,
      runner,
      sleep: () => undefined,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);
    expect(tallyCalls(recorded)).toHaveLength(0);
    // No breadcrumb of ANY shape. The filename is keyed by branch
    // (gh-artifact-pr.<branch-slug>.json), so naming one literal path here
    // would assert the absence of a file nothing can produce; the directory
    // listing is what keeps this assertion able to fail.
    const cacheDir = path.join(sandbox.root, '.gaia', 'local', 'cache');
    const breadcrumbs =
      existsSync(cacheDir) ?
        readdirSync(cacheDir).filter(
          (name) => name.startsWith('gh-artifact-pr') && name.endsWith('.json')
        )
      : [];
    expect(breadcrumbs).toEqual([]);
  });

  test('on main with --branch-aware, merge does not land: auto-merge stays queued, cleanup deferred', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'),
        },
        {
          argv: [
            'pr',
            'view',
            'wiki/sync-2026-05-07-bbbbbbb',
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

    const exit = run(['--branch-aware'], {
      cwd: sandbox.root,
      mergePollAttempts: 3,
      runner,
      sleep: () => undefined,
      today: '2026-05-07',
    });
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain(
      'auto-merge queued but not yet merged, local cleanup deferred'
    );

    // Polled the budget, then returned to base but deferred the local cleanup.
    const pollCalls = recorded.filter(
      (c) =>
        c.command === 'gh' &&
        c.args[0] === 'pr' &&
        c.args[1] === 'view' &&
        c.args.includes('state')
    );
    expect(pollCalls).toHaveLength(3);
    const gitCalls = recorded.filter((c) => c.command === 'git');
    expect(gitCalls).toContainEqual({
      args: ['checkout', '--end-of-options', 'main'],
      command: 'git',
    });
    expect(recorded.find((c) => c.args[0] === 'branch')).toBeUndefined();
    expect(recorded.find((c) => c.args[0] === 'pull')).toBeUndefined();
    expect(recorded.find((c) => c.args[0] === 'fetch')).toBeUndefined();
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
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('cccccccccccccccccccccccccccccccccccccccc\n'),
        },
        {
          argv: ['push', '-u', 'origin', 'wiki/sync-2026-05-07-ccccccc'],
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

  test('protected-branch flow rolls back local steps when commit fails', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('dddddddddddddddddddddddddddddddddddddddd\n'),
        },
        {
          argv: ['commit', '-m', 'wiki: sync through ddddddd'],
          result: failResult(1, 'nothing to commit'),
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

    // After the commit failure the handler returns to the original branch
    // and deletes the half-created sync branch.
    const gitCalls = recorded.filter((c) => c.command === 'git');
    expect(gitCalls).toContainEqual({
      args: ['checkout', 'main'],
      command: 'git',
    });
    expect(gitCalls).toContainEqual({
      args: ['branch', '-D', 'wiki/sync-2026-05-07-ddddddd'],
      command: 'git',
    });
    // The staged `wiki` index is reset before switching branches, so the
    // failed commit does not carry a dirty index onto the original branch.
    const resetIndex = gitCalls.findIndex(
      (c) => c.args.join(' ') === 'reset HEAD -- wiki'
    );
    const checkoutIndex = gitCalls.findIndex(
      (c) => c.args.join(' ') === 'checkout main'
    );
    expect(resetIndex).toBeGreaterThanOrEqual(0);
    expect(resetIndex).toBeLessThan(checkoutIndex);
    // No push / gh once the local sequence failed.
    expect(recorded.find((c) => c.args[0] === 'push')).toBeUndefined();
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('protected-branch flow rolls back safely when the add step fails', () => {
    // Regression: `rollbackLocalLanding` runs `git reset HEAD -- wiki`
    // unconditionally once `onSyncBranch` is set. When the `add` step itself
    // fails, the reset is a harmless no-op and the rollback still returns to
    // the original branch and deletes the half-created sync branch.
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('cccccccccccccccccccccccccccccccccccccccc\n'),
        },
        {
          argv: ['add', 'wiki'],
          result: failResult(1, 'fatal: pathspec error'),
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

    const gitCalls = recorded.filter((c) => c.command === 'git');
    // The `add` failure triggers the local rollback: unstage, return to the
    // original branch, delete the half-created sync branch.
    expect(gitCalls).toContainEqual({
      args: ['reset', 'HEAD', '--', 'wiki'],
      command: 'git',
    });
    expect(gitCalls).toContainEqual({
      args: ['checkout', 'main'],
      command: 'git',
    });
    expect(gitCalls).toContainEqual({
      args: ['branch', '-D', 'wiki/sync-2026-05-07-ccccccc'],
      command: 'git',
    });
    // The commit never runs once `add` fails, and no remote work happens.
    expect(recorded.find((c) => c.args[0] === 'commit')).toBeUndefined();
    expect(recorded.find((c) => c.args[0] === 'push')).toBeUndefined();
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('in-place flow unstages wiki when commit fails after a successful add', () => {
    // Regression: the `staged` flag is derived from a structured `marks`
    // field on the step descriptor, not the first argv token. A failed
    // commit after a successful `add` must still reset the index; proving
    // the derivation does not depend on argv position.
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
        },
        {
          argv: ['rev-parse', 'HEAD'],
          result: okResult('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n'),
        },
        {argv: ['add', 'wiki'], result: okResult('')},
        {
          argv: ['commit', '-m', 'wiki: sync through eeeeeee'],
          result: failResult(1, 'nothing to commit'),
        },
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(2);

    const gitCalls = recorded.filter((c) => c.command === 'git');
    // The successful `add` set the `staged` flag, so the failed commit
    // unstages `wiki` to leave a clean index behind.
    expect(gitCalls).toContainEqual({
      args: ['reset', 'HEAD', '--', 'wiki'],
      command: 'git',
    });
    // No gh calls on the in-place path.
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('working tree with non-wiki changes: exit 1', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M app/foo.ts\0 M wiki/log.md\0'),
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

  test('empty working tree: exit 1', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
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
          argv: ['status', '--porcelain=v1', '-z', '-uall'],
          result: okResult(' M wiki/log.md\0'),
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

  describe('out-of-scope GAIA-Audit stamp', () => {
    const HEAD_SHA = 'dddddddddddddddddddddddddddddddddddddddd';
    const BRANCH = 'wiki/sync-2026-05-07-ddddddd';
    const RECORD_ARGV = [
      'pr',
      'view',
      BRANCH,
      '--json',
      'files,headRefOid,baseRefName',
    ];

    const prRecord = (
      paths: readonly string[],
      headRefOid: string = HEAD_SHA
    ): SpawnSyncReturns<string> =>
      okResult(
        JSON.stringify({
          baseRefName: 'main',
          files: paths.map((filePath) => ({path: filePath})),
          headRefOid,
        })
      );

    const protectedScript = (
      extra: {
        argv: readonly string[];
        result: SpawnSyncReturns<string>;
      }[] = []
    ) => [
      {
        argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
        result: okResult('main\n'),
      },
      {
        argv: ['status', '--porcelain=v1', '-z', '-uall'],
        result: okResult(' M wiki/log.md\0'),
      },
      {argv: ['rev-parse', 'HEAD'], result: okResult(`${HEAD_SHA}\n`)},
      {
        argv: ['pr', 'view', BRANCH, '--json', 'state', '--jq', '.state'],
        result: okResult('MERGED\n'),
      },
      ...extra,
    ];

    const runnerWithResolver = (
      recorded: RecordedCall[],
      record: SpawnSyncReturns<string>,
      resolver: SpawnSyncReturns<string>,
      post: SpawnSyncReturns<string> = okResult(''),
      fetchBase: SpawnSyncReturns<string> = okResult('')
    ): CommandRunner =>
      buildRunner(
        protectedScript([
          {argv: RECORD_ARGV, result: record},
          {argv: ['fetch', 'origin', 'main'], result: fetchBase},
          {
            argv: [
              '.gaia/scripts/resolve-audit-members.sh',
              '--root',
              realpathSync(sandbox.root),
              '--base',
              'origin/main',
            ],
            result: resolver,
          },
          {
            argv: [
              'api',
              '-X',
              'POST',
              `repos/{owner}/{repo}/statuses/${HEAD_SHA}`,
              '-f',
              'state=success',
              '-f',
              'context=GAIA-Audit',
              '-f',
              'description=skipped: out of scope',
            ],
            result: post,
          },
        ]),
        recorded
      );

    test('posts the stamp between pr create and pr merge for a wiki-only diff', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md', 'wiki/concepts/Foo.md']),
        okResult('')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);

      const order = recorded.map((call) => `${call.command} ${call.args[0]}`);
      const create = order.indexOf('gh pr');
      expect(statusCalls(recorded)).toHaveLength(1);
      expect(statusCalls(recorded)[0]?.args).toContain(
        'description=skipped: out of scope'
      );
      const stampIndex = recorded.findIndex(
        (call) => call.command === 'gh' && call.args[0] === 'api'
      );
      const mergeIndex = recorded.findIndex(
        (call) => call.command === 'gh' && call.args[1] === 'merge'
      );
      expect(create).toBeLessThan(stampIndex);
      expect(stampIndex).toBeLessThan(mergeIndex);
      expect(recorded[mergeIndex]?.args).toContain('--auto');
    });

    test('refuses when the roster dispatches a member, still lands with --auto', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md']),
        okResult('code-audit-frontend\n')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('code-audit-frontend');
      expect(stdio.errors.join('')).toContain('PR Merge Workflow');
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });

    test('refuses when the resolver cannot answer, still lands with --auto', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md']),
        failResult(2, 'resolve-audit-members: no auditors roster')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('could not answer');
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });

    test('refuses a diff that leaves wiki/', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md', 'app/root.tsx']),
        okResult('')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('outside wiki/');
    });

    test('a non-wiki path only the pull request carries (local base ahead of origin) posts nothing', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      // The local range main...HEAD would read wiki-only; the pull request
      // record is the only place the extra commit shows.
      const runner = buildRunner(
        protectedScript([
          {
            argv: ['diff', '--name-only', '-z', 'main...HEAD'],
            result: okResult('wiki/log.md\0'),
          },
          {
            argv: RECORD_ARGV,
            result: prRecord(['wiki/log.md', 'app/ahead-of-origin.ts']),
          },
        ]),
        recorded
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('outside wiki/');
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });

    test('reads the pull request, never a local diff, and resolves members against the fetched remote base', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md']),
        okResult('')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(
        recorded.some(
          (call) => call.command === 'git' && call.args[0] === 'diff'
        )
      ).toBe(false);
      const resolverCall = recorded.find((call) =>
        call.args.includes('.gaia/scripts/resolve-audit-members.sh')
      );
      expect(resolverCall?.args.at(-1)).toBe('origin/main');
    });

    test('a pull request head that is not the local HEAD posts nothing', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md'], 'e'.repeat(40)),
        okResult('')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('not the commit this checkout');
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });

    test('a pull request record that cannot be read posts nothing', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        failResult(1, 'HTTP 502'),
        okResult('')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain(
        'could not read the pull request'
      );
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });

    test('a failed fetch of the remote base posts nothing', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md']),
        okResult(''),
        okResult(''),
        failResult(128, 'fatal: unable to access')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(0);
      expect(stdio.errors.join('')).toContain('could not fetch origin/main');
    });

    test('a failing status POST leaves the exit code unchanged and names the manual path', () => {
      sandbox = setupSandbox();
      const recorded: RecordedCall[] = [];
      const runner = runnerWithResolver(
        recorded,
        prRecord(['wiki/log.md']),
        okResult(''),
        failResult(1, 'HTTP 403')
      );

      expect(landProtected(sandbox.root, runner)).toBe(0);
      expect(statusCalls(recorded)).toHaveLength(1);
      expect(stdio.errors.join('')).toContain('HTTP 403');
      expect(stdio.errors.join('')).toContain('PR Merge Workflow');
      expect(recorded.some((call) => call.args.includes('--auto'))).toBe(true);
    });
  });

  describe('statusline cache invalidation', () => {
    test('an in-place land sets checkedAt to 0 and keeps every other key', () => {
      sandbox = setupSandbox();
      seedCache(sandbox.root);

      expect(run([], {cwd: sandbox.root, runner: featureRunner([])})).toBe(0);
      expect(readCache(sandbox.root)).toEqual({
        checkedAt: 0,
        wikiDriftCount: 31,
      });
    });

    test('a protected-branch land that merges sets checkedAt to 0 and keeps every other key', () => {
      sandbox = setupSandbox();
      seedCache(sandbox.root);

      const exit = run(['--branch-aware'], {
        cwd: sandbox.root,
        runner: mainRunner([]),
        sleep: () => undefined,
        today: '2026-05-07',
      });
      expect(exit).toBe(0);
      expect(readCache(sandbox.root)).toEqual({
        checkedAt: 0,
        wikiDriftCount: 31,
      });
    });

    test('creates no cache file when none exists', () => {
      sandbox = setupSandbox();

      expect(run([], {cwd: sandbox.root, runner: featureRunner([])})).toBe(0);
      expect(existsSync(cachePathOf(sandbox.root))).toBe(false);
    });

    test('a land that fails before landing leaves the cache untouched', () => {
      sandbox = setupSandbox();
      seedCache(sandbox.root);

      const exit = run(['--branch-aware'], {
        cwd: sandbox.root,
        runner: mainRunner(
          [],
          [
            {
              argv: ['push', '-u', 'origin', 'wiki/sync-2026-05-07-bbbbbbb'],
              result: failResult(128, 'remote: rejected'),
            },
          ]
        ),
        today: '2026-05-07',
      });
      expect(exit).toBe(2);
      expect(readCache(sandbox.root)).toEqual({
        checkedAt: 1_700_000_000,
        wikiDriftCount: 31,
      });
    });
  });
});
