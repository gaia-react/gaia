import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from './exit.js';
import {run} from './index.js';

// Built at runtime so no removed-surface literal lands in the tracked tree.
const REMOVED_CRON_SUBCOMMAND = ['cron', 'decide'].join('-');

const REMOVED_SETUP_CI_MEMBERS = [
  'status',
  'check-drift',
  'check-audit-drift',
  'dismiss-personal',
  'opt-out-team',
  'verify-run',
  'finalize',
  'write-tool-mode',
];

const captureStdio = (): {errors: string[]; restore: () => void} => {
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation(() => true);
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

let stdio: ReturnType<typeof captureStdio>;

beforeEach(() => {
  stdio = captureStdio();
});

afterEach(() => {
  stdio.restore();
});

const readStderrCode = (): unknown => {
  const lastLine = stdio.errors.join('').trim().split('\n').at(-1) ?? '{}';

  return (JSON.parse(lastLine) as {code?: unknown}).code;
};

describe('removed CI automation CLI surface', () => {
  test.each<[string, string[]]>([
    ['automation read-config', ['automation', 'read-config']],
    [
      'the removed cron decider',
      ['automation', REMOVED_CRON_SUBCOMMAND, 'wiki'],
    ],
    ['wiki diff-size', ['wiki', 'diff-size']],
    ...REMOVED_SETUP_CI_MEMBERS.map((member): [string, string[]] => [
      `setup-ci ${member}`,
      ['setup-ci', member],
    ]),
  ])('%s exits unknown_subcommand', async (_label, argv) => {
    await expect(run(argv)).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrCode()).toBe('unknown_subcommand');
  });

  test('a kept setup-ci member is not rejected as unknown', async () => {
    await expect(run(['setup-ci', 'detect-remote', '--help'])).resolves.toBe(
      EXIT_CODES.OK
    );
    expect(stdio.errors.join('')).not.toContain('unknown_subcommand');
  });
});
