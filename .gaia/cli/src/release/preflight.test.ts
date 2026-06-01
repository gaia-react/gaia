/**
 * Tests for `gaia-maintainer release preflight`.
 */
import {execFileSync, type SpawnSyncReturns} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {type CommandRunner, run} from './preflight.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-preflight-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

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

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

type RecordedCall = {
  args: string[];
  command: string;
};

const buildRunner =
  (
    scripted: Array<{
      argv: readonly string[];
      result: SpawnSyncReturns<string>;
    }>,
    recorded: RecordedCall[]
  ): CommandRunner =>
  (command, args) => {
    recorded.push({args: [...args], command});

    for (const entry of scripted) {
      if (entry.argv.length !== args.length) continue;
      let match = true;

      for (let index = 0; index < entry.argv.length; index += 1) {
        if (entry.argv[index] !== args[index]) {
          match = false;
          break;
        }
      }

      if (match) return entry.result;
    }

    return okResult('');
  };

/** A realistic full 40-char SHA — the value `gaia wiki state` records. */
const STATE_SHA = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
/** `git log` range query uses the resolved (full) SHA. */
const DRIFT_RANGE = `${STATE_SHA}..HEAD`;
/** `git rev-parse --verify` argument that resolves the state SHA. */
const REVPARSE_ARGS = ['rev-parse', '--verify', `${STATE_SHA}^{commit}`];

/**
 * The recovery baseline `gaia wiki state` reports as `suggested_base` when the
 * recorded SHA is orphaned (`reachable:false`) — an abbreviated SHA, like
 * `state_sha`.
 */
const SUGGESTED_BASE = 'f6e5d4c3';
/** `rev-parse --verify` resolves the abbreviated recovery base to a full SHA. */
const SUGGESTED_FULL = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5';
const SUGGESTED_REVPARSE = [
  'rev-parse',
  '--verify',
  `${SUGGESTED_BASE}^{commit}`,
];
const SUGGESTED_COUNT = ['rev-list', '--count', `${SUGGESTED_FULL}..HEAD`];
const SUGGESTED_RANGE = `${SUGGESTED_FULL}..HEAD`;

describe('release preflight', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('exit 0 on main with clean tree and synced wiki', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
    // Success: no stdout, no stderr.
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');
  });

  test('exit 1 when not on main', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('feature/x\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('must be on main');
  });

  test('exit 1 when working tree is dirty', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {
          argv: ['status', '--porcelain=v1', '-uall'],
          result: okResult(' M README.md\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('working tree is dirty');
  });

  test('exit 1 when wiki is behind HEAD with substantive drift', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('feat: a new thing\nwiki: sync through abc1234\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 2,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki is 2 commits behind HEAD');
  });

  test('exit 0 when drift is entirely wiki-sync squash artifacts', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234 (#173)\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 1,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toContain('wiki-sync squash artifact');
  });

  test('exit 1 when drift mixes a wiki artifact with a real commit', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234\nfix: real bug\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 2,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki is 2 commits behind HEAD');
  });

  test('exit 1 when the state SHA cannot be resolved', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {
          argv: REVPARSE_ARGS,
          result: {
            output: ['', '', ''] as never,
            pid: 0,
            signal: null,
            status: 128,
            stderr: 'fatal: ambiguous argument',
            stdout: '',
          },
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 1,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki is 1 commits behind HEAD');
  });

  test('exit 1 when drift commit log cannot be read', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: {
            output: ['', '', ''] as never,
            pid: 0,
            signal: null,
            status: 128,
            stderr: 'fatal: bad revision',
            stdout: '',
          },
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 1,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki is 1 commits behind HEAD');
  });

  test('exit 1 when orphaned state recovers a window with substantive drift', () => {
    // reachable:false is the normal post-squash-merge condition. `gaia wiki
    // state` hardcodes commits_ahead:0 there, so the gate must recover the
    // un-evaluated window from suggested_base..HEAD instead of reading the zero.
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
        {argv: SUGGESTED_COUNT, result: okResult('2\n')},
        {
          argv: ['log', '--format=%s', SUGGESTED_RANGE],
          result: okResult('feat: a real change\nwiki: sync through abc1234\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: false,
        state_sha: STATE_SHA,
        suggested_base: SUGGESTED_BASE,
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('wiki is 2 commits behind HEAD');
    // The orphaned state_sha range is topologically unreliable after a squash —
    // the gate inspects suggested_base..HEAD, never state_sha..HEAD.
    expect(recorded.some((call) => call.args.includes(SUGGESTED_RANGE))).toBe(
      true
    );
    expect(recorded.some((call) => call.args.includes(DRIFT_RANGE))).toBe(false);
  });

  test('exit 0 when orphaned recovered window is only wiki-sync artifacts', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
        {argv: SUGGESTED_COUNT, result: okResult('1\n')},
        {
          argv: ['log', '--format=%s', SUGGESTED_RANGE],
          result: okResult('wiki: sync through abc1234 (#173)\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: false,
        state_sha: STATE_SHA,
        suggested_base: SUGGESTED_BASE,
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toContain('wiki-sync squash artifact');
  });

  test('exit 0 when orphaned state has no recoverable baseline', () => {
    // suggested_base empty means the timestamp predates all history — there is
    // nothing un-evaluated to recover, so today's pass is preserved.
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: false,
        state_sha: '',
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');
    // No recovery probe: no rev-list count, no drift log.
    expect(recorded.every((call) => call.args[0] !== 'rev-list')).toBe(true);
    expect(recorded.every((call) => call.args[0] !== 'log')).toBe(true);
  });

  test('exit 1 when the orphaned recovery count cannot be read', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: SUGGESTED_REVPARSE, result: okResult(`${SUGGESTED_FULL}\n`)},
        {
          argv: SUGGESTED_COUNT,
          result: {
            output: ['', '', ''] as never,
            pid: 0,
            signal: null,
            status: 128,
            stderr: 'fatal: bad revision',
            stdout: '',
          },
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: false,
        state_sha: STATE_SHA,
        suggested_base: SUGGESTED_BASE,
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('cannot determine wiki drift');
  });

  test('reachable path ignores suggested_base and uses state_sha', () => {
    // Defensive regression: the recovery branch is gated on `!reachable`. Even
    // if a payload carried suggested_base while reachable, the count must come
    // from the JSON's commits_ahead and the range from state_sha — byte
    // identical to the pre-recovery behavior.
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('main\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
        {argv: REVPARSE_ARGS, result: okResult(`${STATE_SHA}\n`)},
        {
          argv: ['log', '--format=%s', DRIFT_RANGE],
          result: okResult('wiki: sync through abc1234\n'),
        },
      ],
      recorded
    );

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 1,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: SUGGESTED_BASE,
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.errors.join('')).toContain('wiki-sync squash artifact');
    expect(recorded.some((call) => call.args.includes(DRIFT_RANGE))).toBe(true);
    expect(recorded.some((call) => call.args.includes(SUGGESTED_RANGE))).toBe(
      false
    );
    // Count comes from the JSON, so the reachable path never runs rev-list.
    expect(recorded.every((call) => call.args[0] !== 'rev-list')).toBe(true);
  });

  test('exit 2 when git rev-parse fails', () => {
    const recorded: RecordedCall[] = [];
    const runner: CommandRunner = (_command, _args, _options) => {
      recorded.push({args: [..._args], command: _command});

      return {
        error: new Error('git not found'),
        output: ['', '', ''] as never,
        pid: 0,
        signal: null,
        status: null,
        stderr: '',
        stdout: '',
      };
    };

    const exit = run([], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('preflight:');
  });

  test('--branch overrides allowed release branch', () => {
    const recorded: RecordedCall[] = [];
    const runner = buildRunner(
      [
        {
          argv: ['rev-parse', '--abbrev-ref', 'HEAD'],
          result: okResult('release/v1\n'),
        },
        {argv: ['status', '--porcelain=v1', '-uall'], result: okResult('')},
      ],
      recorded
    );

    const exit = run(['--branch', 'release/v1'], {
      cwd: sandbox.root,
      runner,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {
      cwd: sandbox.root,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--help prints usage', () => {
    const exit = run(['--help'], {
      cwd: sandbox.root,
      wikiStateProbe: () => ({
        commits_ahead: 0,
        reachable: true,
        state_sha: STATE_SHA,
        suggested_base: '',
      }),
    });
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage:');
  });
});
