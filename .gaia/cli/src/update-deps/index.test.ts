import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './index.js';

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

describe('update-deps namespace router', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    vi.restoreAllMocks();
  });

  test('no subcommand prints namespace help and exits 0', async () => {
    const exit = await run([]);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps');
    expect(stdio.outputs.join('')).toContain('run');
  });

  test('--help prints namespace help and exits 0', async () => {
    const exit = await run(['--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps');
  });

  test('unknown subcommand reports a structured error and exits 1', async () => {
    const exit = await run(['bogus']);
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown_subcommand');
  });

  test('run --help prints subcommand usage and exits 0', async () => {
    const exit = await run(['run', '--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps run');
  });

  test('namespace help lists the decline subcommand', async () => {
    const exit = await run([]);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('decline');
  });

  test('decline --help routes to the decline handler and exits 0', async () => {
    const exit = await run(['decline', '--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps decline');
  });
});
