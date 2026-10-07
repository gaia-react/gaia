import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import {run} from './index.js';

const EXPECTED_SUBCOMMANDS = [
  'state',
  'commit-classify',
  'state-init',
  'state-bump',
  'log-prepend',
  'page-index',
  'orphans',
  'near-collisions',
  'dead-paths',
  'frontmatter',
  'empty-sections',
  'chain',
];

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

describe('wiki dispatch', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    vi.restoreAllMocks();
  });

  test('a retired subcommand is unknown, whatever argument follows it', async () => {
    const exit = await run(['sync', 'land', '--branch-aware']);

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain('"code":"unknown_subcommand"');
  });

  test('--help lists exactly the registered subcommands, in order', async () => {
    const exit = await run(['--help']);
    const listed = stdio.outputs
      .join('')
      .split('\n')
      .flatMap((line) => {
        const match = /^ {2}(?! )(\S+)/u.exec(line);

        return match?.[1] === undefined ? [] : [match[1]];
      });

    expect(exit).toBe(EXIT_CODES.OK);
    expect(listed).toEqual(EXPECTED_SUBCOMMANDS);
  });
});
