import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
import {run as runBump} from './bump.js';
import {run} from './index.js';

vi.mock('./bump.js', () => ({run: vi.fn()}));

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

let stdio: ReturnType<typeof captureStdio>;

beforeEach(() => {
  vi.mocked(runBump).mockReset();
  stdio = captureStdio();
});

afterEach(() => {
  stdio.restore();
});

// Read every chunk, not just the first: a lone `calls[0]` read misses a payload
// that arrives in a later write.
const readStderrPayload = (): Record<string, unknown> =>
  JSON.parse(stdio.errors.join('').trim().split('\n').at(-1) ?? '{}') as Record<
    string,
    unknown
  >;

describe('release subcommand router', () => {
  test.each(['--help', '-h', 'help'])(
    '%s prints help and exits 0',
    async (token) => {
      await expect(run([token])).resolves.toBe(EXIT_CODES.OK);
      expect(stdio.outputs.join('')).toContain(
        'Usage: gaia-maintainer release'
      );
      expect(stdio.errors).toHaveLength(0);
    }
  );

  test('no subcommand prints help and exits 0', async () => {
    await expect(run([])).resolves.toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia-maintainer release');
  });

  // The guard this suite exists to pin only earns its keep if dispatch still
  // works. Without this case, emptying SUBCOMMAND_HANDLERS leaves the suite
  // green while every real subcommand is dead.
  test('a known subcommand runs its handler and propagates its exit code', async () => {
    vi.mocked(runBump).mockResolvedValue(7);

    await expect(run(['bump', '--auto'])).resolves.toBe(7);
    expect(runBump).toHaveBeenCalledWith(['--auto']);
  });

  test('an unknown subcommand is rejected', async () => {
    await expect(run(['bogus'])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });

  // A bare `Record` index resolves every `Object.prototype` member, so these
  // tokens would dispatch to an inherited method: the callable ones ran and
  // returned a non-number (silently exiting 0 without doing anything), and
  // `__proto__` resolved to a non-callable and crashed the router. Each must be
  // rejected as an unknown subcommand like any other typo.
  test.each([
    'toString',
    'constructor',
    'valueOf',
    'hasOwnProperty',
    '__proto__',
  ])('the Object.prototype member %s is not a subcommand', async (token) => {
    await expect(run([token])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
    expect(runBump).not.toHaveBeenCalled();
  });
});
