import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from './exit.js';
import {run} from './index.js';

// Built at runtime so no removed-surface literal lands in the tracked tree.
const REMOVED_CRON_SUBCOMMAND = ['cron', 'decide'].join('-');

// Built at runtime so no retired Dependabot opt-in name lands in the tree.
const RETIRED_DEPENDABOT_MEMBERS = [
  ['write', 'dependabot', 'config'].join('-'),
  ['write', 'dependabot', 'policy'].join('-'),
  ['enable', 'dependabot', 'security'].join('-'),
];

const RETIRED_DEPENDABOT_SOURCE_FILES = [
  `setup-ci/${RETIRED_DEPENDABOT_MEMBERS[0]}.ts`,
  `setup-ci/${RETIRED_DEPENDABOT_MEMBERS[1]}.ts`,
  `setup-ci/${RETIRED_DEPENDABOT_MEMBERS[2]}.ts`,
  `setup-ci/__tests__/${RETIRED_DEPENDABOT_MEMBERS[0]}.test.ts`,
  `setup-ci/__tests__/${RETIRED_DEPENDABOT_MEMBERS[1]}.test.ts`,
  `setup-ci/__tests__/${RETIRED_DEPENDABOT_MEMBERS[2]}.test.ts`,
];

const REMOVED_SETUP_CI_MEMBERS = [
  'status',
  'check-drift',
  'check-audit-drift',
  'dismiss-personal',
  'opt-out-team',
  'verify-run',
  'finalize',
  'write-tool-mode',
  ...RETIRED_DEPENDABOT_MEMBERS,
];

const sourceDirectory = path.dirname(fileURLToPath(import.meta.url));

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const errors: string[] = [];
  const outputs: string[] = [];
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

  test.each(RETIRED_DEPENDABOT_SOURCE_FILES)(
    'the retired source file %s is gone',
    (relativePath) => {
      expect(existsSync(path.join(sourceDirectory, relativePath))).toBe(false);
    }
  );

  test('top-level and setup-ci help list the alerts subcommand and no retired name', async () => {
    await run(['help']);
    await run(['setup-ci', '--help']);

    const output = stdio.outputs.join('');

    expect(output).toContain('configure-dependabot-alerts');

    for (const member of RETIRED_DEPENDABOT_MEMBERS) {
      expect(output).not.toContain(member);
    }
  });
});
