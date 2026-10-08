import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from './exit.js';
import {run as runPing} from './ping/index.js';
import {run} from './index.js';

vi.mock('./ping/index.js', () => ({run: vi.fn()}));

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
  vi.mocked(runPing).mockReset();
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

describe('gaia top-level router', () => {
  test('help names its binary', async () => {
    await expect(run(['--help'])).resolves.toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia ');
  });

  // The guard this suite exists to pin only earns its keep if dispatch still
  // works. Without this case, emptying SUBCOMMAND_HANDLERS leaves the suite
  // green while every real subcommand is dead.
  test('a known subcommand runs its handler and propagates its exit code', async () => {
    vi.mocked(runPing).mockResolvedValue(7);

    await expect(run(['ping', '--x'])).resolves.toBe(7);
    expect(runPing).toHaveBeenCalledWith(['--x']);
  });

  test('an unknown subcommand is rejected', async () => {
    await expect(run(['bogus'])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });

  test('the adopter labels namespace does not serve docs', async () => {
    await expect(run(['labels', 'docs'])).resolves.toBe(
      EXIT_CODES.UNKNOWN_SUBCOMMAND
    );
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });
});
