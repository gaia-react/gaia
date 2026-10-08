import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from './exit.js';
import {run} from './index.maintainer.js';
import {run as runLabels} from './labels/maintainer.js';
import {run as runRelease} from './release/index.js';

vi.mock('./release/index.js', () => ({run: vi.fn()}));
vi.mock('./labels/maintainer.js', () => ({run: vi.fn()}));

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
  vi.mocked(runRelease).mockReset();
  vi.mocked(runLabels).mockReset();
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

describe('gaia-maintainer top-level router', () => {
  test('help names its binary', async () => {
    await expect(run(['--help'])).resolves.toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia-maintainer ');
  });

  // The guard this suite exists to pin only earns its keep if dispatch still
  // works. Without this case, emptying SUBCOMMAND_HANDLERS leaves the suite
  // green while every real subcommand is dead.
  test('a known subcommand runs its handler and propagates its exit code', async () => {
    vi.mocked(runRelease).mockResolvedValue(7);

    await expect(run(['release', 'bump'])).resolves.toBe(7);
    expect(runRelease).toHaveBeenCalledWith(['bump']);
  });

  test('an unknown subcommand is rejected', async () => {
    await expect(run(['bogus'])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({code: 'unknown_subcommand'});
  });

  test('labels docs dispatches to the maintainer labels handler', async () => {
    vi.mocked(runLabels).mockResolvedValue(0);

    await expect(run(['labels', 'docs', '--help'])).resolves.toBe(0);
    expect(runLabels).toHaveBeenCalledWith(['docs', '--help']);
  });
});
