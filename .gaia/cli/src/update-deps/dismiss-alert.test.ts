import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import type {GhOptions, GhResult} from '../setup-ci/util/gh.js';
import {run} from './dismiss-alert.js';
import type {DismissAlertOptions} from './dismiss-alert.js';

const GITHUB_ORIGIN = 'git@github.com:acme/widgets.git';

type GhRunner = NonNullable<DismissAlertOptions['ghRunner']>;

let outputs: string[];

beforeEach(() => {
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const stdout = (): string => outputs.join('');
const result = (): Record<string, unknown> =>
  JSON.parse(stdout()) as Record<string, unknown>;

const SUCCESS: GhResult = {ok: true, stdout: '{}'};

const recordingGh = (
  response: GhResult = SUCCESS
): {calls: GhOptions[]; ghRunner: GhRunner} => {
  const calls: GhOptions[] = [];

  return {
    calls,
    ghRunner: async (options) => {
      calls.push(options);

      return response;
    },
  };
};

const validArgs = (overrides: string[] = []): string[] => [
  '--alert',
  '41',
  '--reason',
  'tolerable_risk',
  '--comment',
  'accepted by the team',
  '--confirmed',
  ...overrides,
];

// A later duplicate flag wins, so an override replaces the default value.
const withFlag = (flag: string, value: string): string[] => [
  ...validArgs().flatMap((token, index, all) =>
    token === flag || all[index - 1] === flag ? [] : [token]
  ),
  flag,
  value,
];

const dismiss = async (
  argv: string[],
  options: Partial<DismissAlertOptions> & {ghRunner: GhRunner}
): Promise<number> =>
  run(argv, {
    cwd: '/nonexistent-gaia-dismiss',
    env: {},
    originReader: () => GITHUB_ORIGIN,
    ...options,
  });

describe('dismiss-alert refusals send no request', () => {
  test.each([
    ['CI=true', {CI: 'true'}, validArgs(), 'refused-ci'],
    [
      'GITHUB_ACTIONS=true',
      {GITHUB_ACTIONS: 'true'},
      validArgs(),
      'refused-ci',
    ],
    [
      'no --confirmed',
      {},
      validArgs().filter((token) => token !== '--confirmed'),
      'not-confirmed',
    ],
  ])('%s exits 1', async (_label, env, argv, token) => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(argv, {env, ghRunner});

    expect(exit).toBe(1);
    expect(result()).toStrictEqual({alert: 41, dismissed: false, error: token});
    expect(calls).toHaveLength(0);
  });

  test('CI=false does not count as CI', async () => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(validArgs(), {env: {CI: 'false'}, ghRunner});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(calls).toHaveLength(1);
  });

  test('a gitlab.com origin is non-github-remote', async () => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(validArgs(), {
      ghRunner,
      originReader: () => 'git@gitlab.com:acme/widgets.git',
    });

    expect(exit).toBe(1);
    expect(result().error).toBe('non-github-remote');
    expect(calls).toHaveLength(0);
  });

  test('a missing origin is no-remote', async () => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(validArgs(), {
      ghRunner,
      originReader: () => null,
    });

    expect(exit).toBe(1);
    expect(result().error).toBe('no-remote');
    expect(calls).toHaveLength(0);
  });

  test.each([
    ['alert abc', withFlag('--alert', 'abc')],
    ['alert 0', withFlag('--alert', '0')],
    ['alert 1.5', withFlag('--alert', '1.5')],
    ['reason fix_started', withFlag('--reason', 'fix_started')],
    ['a 300 character comment', withFlag('--comment', 'x'.repeat(300))],
    [
      'an over-long 281 character comment',
      withFlag('--comment', 'y'.repeat(281)),
    ],
    ['an empty comment', withFlag('--comment', '')],
    ['an unknown flag', validArgs(['--bogus', 'x'])],
  ])('%s is invalid-arguments and exits 2', async (_label, argv) => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(argv, {ghRunner});

    expect(exit).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(result().error).toBe('invalid-arguments');
    expect(calls).toHaveLength(0);
  });
});

describe('dismiss-alert request', () => {
  test('a valid 280 character comment sends exactly one PATCH as an argv array', async () => {
    const comment = 'c'.repeat(280);
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(withFlag('--comment', comment), {ghRunner});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(result()).toStrictEqual({alert: 41, dismissed: true});
    expect(calls).toHaveLength(1);
    expect(calls[0]?.args).toStrictEqual([
      'api',
      '-X',
      'PATCH',
      'repos/acme/widgets/dependabot/alerts/41',
      '-f',
      'state=dismissed',
      '-f',
      'dismissed_reason=tolerable_risk',
      '-f',
      `dismissed_comment=${comment}`,
    ]);
  });

  test('the comment length counts code points, not UTF-16 units', async () => {
    const {calls, ghRunner} = recordingGh();
    const exit = await dismiss(withFlag('--comment', '\u{1F600}'.repeat(280)), {
      ghRunner,
    });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(calls).toHaveLength(1);
  });

  test('HTTP 403 is forbidden, the call carries a timeout, and stderr never reaches stdout', async () => {
    const {calls, ghRunner} = recordingGh({
      exitCode: 1,
      ok: false,
      stderr: 'gh: Forbidden (HTTP 403) token ghp_secret',
    });
    const exit = await dismiss(validArgs(), {ghRunner});

    expect(exit).toBe(1);
    expect(result()).toStrictEqual({
      alert: 41,
      dismissed: false,
      error: 'forbidden',
    });
    expect(stdout()).not.toContain('ghp_secret');
    expect(calls[0]?.timeoutMs).toBe(60_000);
  });

  test('a timed out call is request-failed even if its stderr mentions 403', async () => {
    const {ghRunner} = recordingGh({
      exitCode: -1,
      ok: false,
      stderr: 'HTTP 403',
      timedOut: true,
    });
    const exit = await dismiss(validArgs(), {ghRunner});

    expect(exit).toBe(1);
    expect(result().error).toBe('request-failed');
  });

  test('any other failure is request-failed and echoes no stderr', async () => {
    const {ghRunner} = recordingGh({
      exitCode: 1,
      ok: false,
      stderr: 'HTTP 500 ghp_secret',
    });
    const exit = await dismiss(validArgs(), {ghRunner});

    expect(exit).toBe(1);
    expect(result().error).toBe('request-failed');
    expect(stdout()).not.toContain('ghp_secret');
  });

  test('--help prints usage naming the verb and exits 0', async () => {
    const {ghRunner} = recordingGh();

    expect(await dismiss(['--help'], {ghRunner})).toBe(EXIT_CODES.OK);
    expect(stdout()).toContain('Usage: gaia update-deps dismiss-alert');
  });
});
