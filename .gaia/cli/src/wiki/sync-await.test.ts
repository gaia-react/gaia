/**
 * Strategy mirrors `sync-land.test.ts`: a real (empty) git repo so
 * `resolveRepoRoot` has something to resolve, then an injected fake
 * `CommandRunner` keyed off argv (with per-argv call sequencing, so a
 * repeated `gh pr view` can answer OPEN then MERGED across successive
 * polls). `sleep` is always a no-op; the real `waitForMerge` budget is
 * minutes long and no test should block on it.
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
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {run} from './sync-await.js';
import {defaultRunner} from './util/branch.js';
import type {CommandRunner} from './util/branch.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-sync-await-'));
  execFileSync('git', ['init', '-q'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

// Set explicitly so commits succeed in CI environments without a configured
// git user.
const GIT_IDENTITY_ENV = {
  GIT_AUTHOR_EMAIL: 'gaia-test@example.com',
  GIT_AUTHOR_NAME: 'GAIA Test',
  GIT_COMMITTER_EMAIL: 'gaia-test@example.com',
  GIT_COMMITTER_NAME: 'GAIA Test',
};

type WorktreeSandbox = {
  cleanup: () => void;
  /** Path to the linked worktree. */
  linkedRoot: string;
  /** Path to the main checkout. Shared (`cache/shared/`) state must resolve here. */
  mainRoot: string;
};

/**
 * Real main checkout + real linked worktree (mirrors
 * `setup/__tests__/setup-worktree.test.ts`'s `setupWorktreeSandbox`), for
 * exercising `resolveMainWorktreeRoot` and `git worktree`-visible refs for
 * real. `resolveMainWorktreeRoot`/`resolveRepoRoot` shell out directly
 * (`execGaiaGit`), not through the injected `CommandRunner`, so this needs an
 * actual on-disk worktree pair rather than a mock.
 */
const setupWorktreeSandbox = (branch: string): WorktreeSandbox => {
  const parent = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-await-wt-'));
  const mainRoot = path.join(parent, 'main');
  const linkedRoot = path.join(parent, 'linked');

  mkdirSync(mainRoot, {recursive: true});
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: mainRoot});
  execFileSync('git', ['commit', '--allow-empty', '-q', '-m', 'init'], {
    cwd: mainRoot,
    env: {...process.env, ...GIT_IDENTITY_ENV},
  });
  execFileSync('git', ['branch', branch], {cwd: mainRoot});
  execFileSync('git', ['worktree', 'add', '-q', linkedRoot, branch], {
    cwd: mainRoot,
    env: {...process.env, ...GIT_IDENTITY_ENV},
  });

  return {
    cleanup: () => {
      rmSync(parent, {force: true, recursive: true});
    },
    linkedRoot,
    mainRoot,
  };
};

const captureStdio = (): {
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
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

const failResult = (status = 1, stderr = ''): SpawnSyncReturns<string> => ({
  output: ['', '', stderr] as never,
  pid: 0,
  signal: null,
  status,
  stderr,
  stdout: '',
});

type Rule = {
  argv: readonly string[];
  command: string;
  results: readonly SpawnSyncReturns<string>[];
};

/**
 * argv-matched, call-sequenced fake runner: the Nth call matching a rule's
 * exact `[command, ...argv]` returns that rule's Nth scripted result (the
 * last result repeats for any call beyond the scripted sequence). Any call
 * matching no rule gets a default success with empty stdout, mirroring
 * `sync-land.test.ts`'s `buildRunner` default.
 */
const buildRunner = (
  rules: readonly Rule[],
  recorded: RecordedCall[]
): CommandRunner => {
  const counters = new Map<string, number>();

  return (command, args) => {
    recorded.push({args: [...args], command});

    const rule = rules.find(
      (candidate) =>
        candidate.command === command &&
        candidate.argv.length === args.length &&
        candidate.argv.every((token, index) => token === args[index])
    );

    if (rule === undefined) return okResult('');

    const key = `${command} ${args.join('\u0000')}`;
    const index = counters.get(key) ?? 0;
    counters.set(key, index + 1);

    const result = rule.results[Math.min(index, rule.results.length - 1)];

    if (result === undefined) {
      throw new Error(
        `buildRunner: rule for ${key} has an empty results array`
      );
    }

    return result;
  };
};

const forEachRefRule = (branches: readonly string[]): Rule => ({
  argv: [
    'for-each-ref',
    '--sort=-committerdate',
    '--format=%(refname:short)',
    'refs/heads/wiki-sync/',
  ],
  command: 'git',
  results: [okResult(branches.length === 0 ? '' : `${branches.join('\n')}\n`)],
});

const symbolicRefHeadRule = (current: string): Rule => ({
  argv: ['symbolic-ref', '--quiet', '--short', 'HEAD'],
  command: 'git',
  results: [okResult(`${current}\n`)],
});

// Detached HEAD, or otherwise unresolvable: `discoverBranch` excludes nothing.
const symbolicRefHeadFailsRule = (): Rule => ({
  argv: ['symbolic-ref', '--quiet', '--short', 'HEAD'],
  command: 'git',
  results: [failResult(1, '')],
});

const prViewRule = (
  branch: string,
  states: readonly ('CLOSED' | 'MERGED' | 'OPEN')[]
): Rule => ({
  argv: ['pr', 'view', branch, '--json', 'state', '--jq', '.state'],
  command: 'gh',
  results: states.map((state) => okResult(`${state}\n`)),
});

// gh's definitive "this PR does not exist for this branch" message: a
// permanent state, e.g. a `wiki-sync/*` branch whose push failed and was
// left behind with no PR ever opened.
const prViewNoPrRule = (branch: string): Rule => ({
  argv: ['pr', 'view', branch, '--json', 'state', '--jq', '.state'],
  command: 'gh',
  results: [
    failResult(1, 'no pull requests found for branch "does-not-matter"'),
  ],
});

// A transient failure (network/auth, or a lookup that raced the PR's
// creation): not a real signal either way, distinct from the definitive
// no-PR message above.
const prViewTransientFailRule = (branch: string): Rule => ({
  argv: ['pr', 'view', branch, '--json', 'state', '--jq', '.state'],
  command: 'gh',
  results: [failResult(1, 'GraphQL: connection reset by peer')],
});

const noSleep = (): void => undefined;

describe('wiki sync await', () => {
  let sandbox: Sandbox | undefined;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox?.cleanup();
    sandbox = undefined;
    delete process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS;
    vi.restoreAllMocks();
  });

  test('no wiki-sync branch: silent no-op, exit 0', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner([forEachRefRule([])], recorded);

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('the current checkout is never a candidate', () => {
    sandbox = setupSandbox();
    const older = 'wiki-sync/2026-08-07-aaaaaaa';
    const newer = 'wiki-sync/2026-08-07-bbbbbbb';

    // Two same-day branches; the newer one is checked out. The verb must
    // select the older, non-checked-out branch.
    const recordedFirst: RecordedCall[] = [];
    const firstRunner = buildRunner(
      [
        forEachRefRule([older, newer]),
        symbolicRefHeadRule(newer),
        prViewRule(older, ['CLOSED']),
      ],
      recordedFirst
    );

    run([], {cwd: sandbox.root, runner: firstRunner, sleep: noSleep});

    const ghCallsFirst = recordedFirst.filter((c) => c.command === 'gh');
    expect(ghCallsFirst).toHaveLength(1);
    expect(ghCallsFirst[0]?.args).toContain(older);
    expect(ghCallsFirst[0]?.args).not.toContain(newer);

    // With the checked-out branch as the ONLY candidate, excluding it empties
    // the candidate set: silent no-op, no gh call, no checkout.
    stdio.restore();
    stdio = captureStdio();
    const recordedSecond: RecordedCall[] = [];
    const secondRunner = buildRunner(
      [forEachRefRule([newer]), symbolicRefHeadRule(newer)],
      recordedSecond
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner: secondRunner,
      sleep: noSleep,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(recordedSecond.filter((c) => c.command === 'gh')).toHaveLength(0);
    expect(
      recordedSecond.find((c) => c.args[0] === 'checkout')
    ).toBeUndefined();
  });

  test('the verb is dispatched and documented', async () => {
    vi.resetModules();
    const mockedRun = vi.fn().mockReturnValue(EXIT_CODES.OK);
    vi.doMock('./sync-await.js', () => ({run: mockedRun}));

    const wikiIndex = await import('./index.js');
    const code = await wikiIndex.run(['sync', 'await', 'ignored-arg']);

    expect(code).toBe(EXIT_CODES.OK);
    expect(mockedRun).toHaveBeenCalledWith(['ignored-arg']);

    vi.doUnmock('./sync-await.js');
    vi.resetModules();

    // SYNC_HELP_TEXT names `await`.
    const helpStdio = captureStdio();
    const freshWikiIndex = await import('./index.js');
    await freshWikiIndex.run(['sync', '--help']);
    helpStdio.restore();
    expect(helpStdio.outputs.join('')).toContain('await');

    // Both entrypoints carry `sync await` in the free-form tail.
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const indexSource = readFileSync(
      path.join(repoRoot, '.gaia', 'cli', 'src', 'index.ts'),
      'utf8'
    );
    const maintainerSource = readFileSync(
      path.join(repoRoot, '.gaia', 'cli', 'src', 'index.maintainer.ts'),
      'utf8'
    );

    expect(indexSource).toContain('sync land|sync await');
    expect(maintainerSource).toContain('sync land|sync await');
  });

  test('a wiki-sync branch with a real CLOSED PR: silent no-op', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['CLOSED']),
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('gh pr view failing with the definitive no-PR message: treated as closed, silent no-op', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    // gh's definitive "this PR does not exist" message: a branch left
    // behind with no PR (e.g. `sync land`'s push failed) will never turn
    // into MERGED/OPEN, so this must give up on the first look, exactly
    // like a real CLOSED state, not ride the ceiling-bound poll.
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewNoPrRule(branch),
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(1);
  });

  test('gh pr view failing with a transient error: unknown, costs exactly one gh call (not a full poll slice), reports pending', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    // A transient failure (network/auth, or a lookup that races the PR's
    // creation) is not the same signal as gh's definitive no-PR message and
    // must not give up silently, but it also must not spend
    // `waitForMerge`'s own bounded poll (up to `mergePollAttempts()` further
    // `gh` calls) chasing a lookup that has not even confirmed a PR exists.
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewTransientFailRule(branch),
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );
    // Exactly one gh call total: the lookup itself. The old behavior rode
    // the same ceiling-bound poll as OPEN, costing up to `mergePollAttempts()`
    // further calls on every invocation.
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(1);
  });

  test('a branch name that does not match the landing shape is ignored', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [forEachRefRule(['wiki-sync/../../evil', 'wiki-sync/nonsense'])],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
    expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    expect(recorded.find((c) => c.args.includes('-D'))).toBeUndefined();
  });

  test('merge lands inside the slice: reports merged and cleans up', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    // HEAD is on base ('main', the default when no origin/HEAD rule is
    // given): the precondition the merged-cleanup gate requires.
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadRule('main'),
        prViewRule(branch, ['OPEN', 'MERGED']),
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain(
      `sync-await: merged PR for ${branch} and cleaned up locally`
    );
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: merged'
    );

    // arrayContaining tolerates the extra HEAD/base resolution calls the
    // merged-cleanup gate makes ahead of the actual cleanup steps.
    const gitCalls = recorded.filter((c) => c.command === 'git');
    expect(gitCalls.map((c) => c.args[0])).toEqual(
      expect.arrayContaining(['checkout', 'pull', 'branch', 'fetch'])
    );
    const branchDelete = gitCalls.find((c) => c.args[0] === 'branch');
    expect(branchDelete?.args).toEqual(['branch', '-D', '--', branch]);
  });

  test('HEAD on a third, unrelated branch: merged catch-up cannot run from here; reports exhausted, not pending, and stays terminal across repeated invocations', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    // Neither the candidate branch nor base: a session working on unrelated
    // feature work while a merged-but-unreaped wiki-sync branch lingers from
    // an earlier session. HEAD does not move between invocations on its
    // own, so this is a stop, not a retry: a `pending` marker here would
    // tell the router to call this verb again forever with byte-identical
    // input and output (an unbounded, no-sleep command loop).
    const unrelated = 'feature/unrelated-work';

    const makeRunner = (recorded: RecordedCall[]): CommandRunner =>
      buildRunner(
        [
          forEachRefRule([branch]),
          symbolicRefHeadRule(unrelated),
          prViewRule(branch, ['MERGED']),
        ],
        recorded
      );

    // Three separate invocations (fresh runner/recorder each time, mirroring
    // three separate CLI processes the router might spawn) must each
    // independently stop, proving repeated invocations terminate rather than
    // looping.
    for (let index = 0; index < 3; index += 1) {
      const recorded: RecordedCall[] = [];
      const exit = run([], {
        cwd: sandbox.root,
        runner: makeRunner(recorded),
        sleep: noSleep,
      });

      expect(exit).toBe(EXIT_CODES.OK);
      expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
      expect(recorded.find((c) => c.args[0] === 'pull')).toBeUndefined();
      expect(recorded.find((c) => c.args.includes('-D'))).toBeUndefined();
    }

    const output = stdio.outputs.join('');
    expect(output).not.toContain('WIKI_AWAIT: pending');
    expect(
      output.split('\n').filter((line) => line === 'WIKI_AWAIT: exhausted')
    ).toHaveLength(3);
    // Honest reason (the merge landed but HEAD is not on base), not a
    // reused-and-misleading ceiling summary.
    expect(output).toContain('HEAD is not on the base branch');
  });

  test('same-day branches: the more recently committed one wins the tie-break, not the lexicographically larger sha', () => {
    sandbox = setupSandbox();
    // `for-each-ref --sort=-committerdate` returns most-recent-first; the
    // mocked order below encodes that git-side sort directly. `aaaaaaa`
    // sorts BEFORE `zzzzzzz` lexicographically but is mocked as the MORE
    // recently committed of the two, so a lexicographic tie-break (the old,
    // buggy behavior) and a committerdate tie-break (the fix) disagree on
    // which branch is "the one actually in flight".
    const recentByCommit = 'wiki-sync/2026-08-07-aaaaaaa';
    const olderByCommit = 'wiki-sync/2026-08-07-zzzzzzz';
    const unrelated = 'feature/unrelated-work';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([recentByCommit, olderByCommit]),
        symbolicRefHeadRule(unrelated),
        prViewRule(recentByCommit, ['CLOSED']),
      ],
      recorded
    );

    run([], {cwd: sandbox.root, runner, sleep: noSleep});

    const ghCalls = recorded.filter((c) => c.command === 'gh');
    expect(ghCalls).toHaveLength(1);
    expect(ghCalls[0]?.args).toContain(recentByCommit);
    expect(ghCalls[0]?.args).not.toContain(olderByCommit);
  });

  test('already MERGED on the first look: cleans up without waiting', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    let sleepCalls = 0;
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadRule('main'),
        prViewRule(branch, ['MERGED']),
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      sleep: () => {
        sleepCalls += 1;
      },
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(sleepCalls).toBe(0);
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(1);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: merged'
    );
  });

  test('slice exhausts: reports pending, never an error', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']), // repeats OPEN for every poll
      ],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    const output = stdio.outputs.join('');
    expect(output.trimEnd().split('\n').at(-1)).toBe('WIKI_AWAIT: pending');
    expect(output).toContain('janitor');
    expect(recorded.find((c) => c.args[0] === 'checkout')).toBeUndefined();
    expect(recorded.find((c) => c.args.includes('-D'))).toBeUndefined();
  });

  test('loop ceiling reached: reports exhausted', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      recorded
    );

    const stateDir = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-await-state-'));
    const nowMs = 1_700_000_000_000;
    // Default ceiling is 660s; seed the state file well past it.
    writeFileSync(
      path.join(stateDir, 'wiki-await.json'),
      JSON.stringify({branch, started_at: nowMs - 700_000}),
      'utf8'
    );

    const exit = run([], {
      cwd: sandbox.root,
      now: () => nowMs,
      runner,
      sleep: noSleep,
      stateDir,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: exhausted'
    );
    // No further poll: the ceiling gate short-circuits before waitForMerge.
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(1);

    rmSync(stateDir, {force: true, recursive: true});
  });

  test('GAIA_WIKI_AWAIT_CEILING_SECONDS=0 disables the await', () => {
    sandbox = setupSandbox();
    process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS = '0';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [forEachRefRule(['wiki-sync/2026-08-07-aaaaaaa'])],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('a whitespace-padded "0" override still disables the await, not clamped up to the floor', () => {
    sandbox = setupSandbox();
    // The raw string is ' 0 ', not '0': must be trimmed before the opt-out
    // comparison, or it falls through to `Number(' 0 ')` (also 0) and gets
    // clamped UP to the 60s floor instead of disabling the await.
    process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS = ' 0 ';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [forEachRefRule(['wiki-sync/2026-08-07-aaaaaaa'])],
      recorded
    );

    const exit = run([], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(recorded.filter((c) => c.command === 'gh')).toHaveLength(0);
  });

  test('a filesystem error writing the durable state file does not escape run (guarded, never fails)', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      recorded
    );

    // A regular file where the state directory would go: `mkdirSync(...,
    // {recursive: true})` cannot create a directory at a path a file
    // already occupies, simulating a wedged EACCES/EROFS/ENOSPC filesystem.
    const badStateRoot = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-await-badstate-')
    );
    const stateDirAsFile = path.join(badStateRoot, 'not-a-directory');
    writeFileSync(stateDirAsFile, '', 'utf8');

    let exit = -1;

    expect(() => {
      exit = run([], {
        cwd: sandbox!.root,
        runner,
        sleep: noSleep,
        stateDir: stateDirAsFile,
      });
    }).not.toThrow();

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );

    rmSync(badStateRoot, {force: true, recursive: true});
  });

  test('--help prints usage and touches no git or gh command', () => {
    sandbox = setupSandbox();
    const recorded: RecordedCall[] = [];
    const runner = buildRunner([], recorded);

    const exit = run(['--help'], {cwd: sandbox.root, runner, sleep: noSleep});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia wiki sync await');
    expect(recorded).toHaveLength(0);
  });

  test('an empty ceiling override falls back to the default, not the floor', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const nowMs = 1_700_000_000_000;
    // Strictly between the 60s floor and the 660s default: elapsed exceeds
    // the floor (would report exhausted if the empty override collapsed to
    // it) but not the default (must report pending if it correctly falls
    // back to the default).
    const elapsedMs = 100_000;

    process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS = '';
    const stateDir = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-await-empty-'));
    writeFileSync(
      path.join(stateDir, 'wiki-await.json'),
      JSON.stringify({branch, started_at: nowMs - elapsedMs}),
      'utf8'
    );
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      now: () => nowMs,
      runner,
      sleep: noSleep,
      stateDir,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );

    rmSync(stateDir, {force: true, recursive: true});
  });

  test('the ceiling knob is floor-clamped', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const nowMs = 1_700_000_000_000;
    // Strictly between the unclamped `=1` override and the 60s floor: an
    // unclamped ceiling of 1s is already exceeded, while the clamped 60s
    // floor is not, so the two verdicts diverge and the floor clamp is the
    // only thing that can produce "pending" here.
    const elapsedMs = 30_000;

    const seedState = (stateDir: string): void => {
      writeFileSync(
        path.join(stateDir, 'wiki-await.json'),
        JSON.stringify({branch, started_at: nowMs - elapsedMs}),
        'utf8'
      );
    };

    // `=1` clamps to the 60s floor: 30s elapsed does not exceed 60s, so the
    // await proceeds to a real poll and reports pending, not exhausted.
    process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS = '1';
    const floorStateDir = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-await-floor-')
    );
    seedState(floorStateDir);
    const floorRecorded: RecordedCall[] = [];
    const floorRunner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      floorRecorded
    );
    const floorExit = run([], {
      cwd: sandbox.root,
      now: () => nowMs,
      runner: floorRunner,
      sleep: noSleep,
      stateDir: floorStateDir,
    });
    expect(floorExit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );
    // The mutant (unclamped `=1`) short-circuits before any poll; the
    // correct floor-clamped behavior actually calls out to `gh`.
    expect(
      floorRecorded.filter((c) => c.command === 'gh').length
    ).toBeGreaterThan(0);
    rmSync(floorStateDir, {force: true, recursive: true});

    // `=abc` falls back to the 660s default: 30s elapsed does not exceed it
    // either, so this arm also reports pending.
    stdio.restore();
    stdio = captureStdio();
    process.env.GAIA_WIKI_AWAIT_CEILING_SECONDS = 'abc';
    const defaultStateDir = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-await-default-')
    );
    seedState(defaultStateDir);
    const defaultRecorded: RecordedCall[] = [];
    const defaultRunnerFn = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      defaultRecorded
    );
    const defaultExit = run([], {
      cwd: sandbox.root,
      now: () => nowMs,
      runner: defaultRunnerFn,
      sleep: noSleep,
      stateDir: defaultStateDir,
    });
    expect(defaultExit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );
    rmSync(defaultStateDir, {force: true, recursive: true});
  });

  test('both waits draw on ONE budget symbol', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const source = readFileSync(
      path.join(repoRoot, '.gaia', 'cli', 'src', 'wiki', 'sync-await.ts'),
      'utf8'
    );

    expect(source).toMatch(/attempts:\s*mergePollAttempts\(\)/u);
    expect(source).not.toMatch(/const\s+\w*ATTEMPT\w*\s*=\s*\d/iu);
  });

  test('cleanupAfterMerge has exactly one definition and two call sites', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');

    const walk = (dir: string): string[] => {
      const entries = readdirSync(dir, {withFileTypes: true});
      const files: string[] = [];

      for (const entry of entries) {
        const abs = path.join(dir, entry.name);
        const isSkippedDir =
          entry.name === 'node_modules' || entry.name === 'dist';

        if (entry.isDirectory()) {
          if (!isSkippedDir) files.push(...walk(abs));
        } else if (
          entry.name.endsWith('.ts') &&
          !entry.name.endsWith('.test.ts')
        ) {
          files.push(abs);
        }
      }

      return files;
    };

    let definitionCount = 0;
    let callCount = 0;

    for (const file of walk(cliSrc)) {
      const contents = readFileSync(file, 'utf8');
      definitionCount += (
        contents.match(/^export const cleanupAfterMerge = /gmu) ?? []
      ).length;
      callCount += (contents.match(/cleanupAfterMerge\(/gu) ?? []).length;
    }

    expect(definitionCount).toBe(1);
    // Each call site's occurrence of `cleanupAfterMerge(` is itself one of
    // the `callCount` matches; the definition line does not match (it reads
    // `cleanupAfterMerge = (`, with a space before the paren).
    expect(callCount).toBeGreaterThanOrEqual(2);
  });

  test('the durable state file resolves to the MAIN checkout, not a linked worktree calling from elsewhere', () => {
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const worktree = setupWorktreeSandbox(branch);

    try {
      const recorded: RecordedCall[] = [];
      // Only the OTHER wiki-sync candidate is discovered here, so this run
      // takes the still-pending path (writes the durable state file) rather
      // than the merged-cleanup path, which is enough to prove where the
      // state file lands.
      const runner = buildRunner(
        [
          forEachRefRule([branch]),
          symbolicRefHeadFailsRule(),
          prViewRule(branch, ['OPEN']),
        ],
        recorded
      );

      const exit = run([], {
        cwd: worktree.linkedRoot,
        runner,
        sleep: noSleep,
      });

      expect(exit).toBe(EXIT_CODES.OK);

      const mainStatePath = path.join(
        worktree.mainRoot,
        '.gaia',
        'local',
        'cache',
        'shared',
        'wiki-await.json'
      );
      const linkedStatePath = path.join(
        worktree.linkedRoot,
        '.gaia',
        'local',
        'cache',
        'shared',
        'wiki-await.json'
      );

      expect(existsSync(mainStatePath)).toBe(true);
      expect(existsSync(linkedStatePath)).toBe(false);
    } finally {
      worktree.cleanup();
    }
  });

  test('a merged branch still checked out in another worktree: branch -D is refused, so the report is exhausted, not merged, and the branch survives', () => {
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const worktree = setupWorktreeSandbox(branch);

    try {
      // Real git for the git half (so `branch -D` genuinely hits the
      // worktree-checkout refusal), scripted `gh` for the merged PR lookup.
      const runner: CommandRunner = (command, args, options) => {
        if (command === 'gh') {
          if (args[0] === 'pr' && args[1] === 'view' && args[2] === branch)
            return {
              output: ['', 'MERGED\n', ''] as never,
              pid: 0,
              signal: null,
              status: 0,
              stderr: '',
              stdout: 'MERGED\n',
            };

          return {
            output: ['', '', ''] as never,
            pid: 0,
            signal: null,
            status: 0,
            stderr: '',
            stdout: '',
          };
        }

        return defaultRunner(command, args, options);
      };

      const exit = run([], {
        cwd: worktree.mainRoot,
        runner,
        sleep: noSleep,
      });

      expect(exit).toBe(EXIT_CODES.OK);
      const output = stdio.outputs.join('');
      expect(output.trimEnd().split('\n').at(-1)).toBe('WIKI_AWAIT: exhausted');
      expect(output).toContain('could not be deleted');

      // `branch -D` was refused; the branch is still there, still checked
      // out by the linked worktree.
      const branchList = execFileSync('git', ['branch', '--list', branch], {
        cwd: worktree.mainRoot,
        encoding: 'utf8',
      });
      expect(branchList).toContain(branch);
    } finally {
      worktree.cleanup();
    }
  });

  test('a future started_at in the durable state is treated as no prior state, restarting the clock instead of disabling the ceiling', () => {
    sandbox = setupSandbox();
    const branch = 'wiki-sync/2026-08-07-aaaaaaa';
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        forEachRefRule([branch]),
        symbolicRefHeadFailsRule(),
        prViewRule(branch, ['OPEN']),
      ],
      recorded
    );

    const stateDir = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-await-future-')
    );
    const nowMs = 1_700_000_000_000;
    // Clock skew or a corrupted/hand-edited file: `started_at` is AFTER
    // `now`. `now() - startedAt` would be negative, so a ceiling comparison
    // against it can never trip.
    const futureStartedAt = nowMs + 1_000_000_000;
    const statePath = path.join(stateDir, 'wiki-await.json');
    writeFileSync(
      statePath,
      JSON.stringify({branch, started_at: futureStartedAt}),
      'utf8'
    );

    const exit = run([], {
      cwd: sandbox.root,
      now: () => nowMs,
      runner,
      sleep: noSleep,
      stateDir,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('').trimEnd().split('\n').at(-1)).toBe(
      'WIKI_AWAIT: pending'
    );

    // The bug: a future `started_at` is accepted as valid prior state, so it
    // is never rewritten (the write is gated on "no prior state") and the
    // corrupted future value sits there forever, permanently defeating the
    // ceiling. The fix rejects it as prior state and restarts the clock at
    // `now()`.
    const rewritten = JSON.parse(readFileSync(statePath, 'utf8')) as {
      branch: string;
      started_at: number;
    };
    expect(rewritten.started_at).toBe(nowMs);

    rmSync(stateDir, {force: true, recursive: true});
  });
});
