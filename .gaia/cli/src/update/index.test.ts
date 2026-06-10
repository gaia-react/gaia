/**
 * Tests for the `gaia update` subcommand router.
 *
 * The router hosts only the field-aware `merge-workspace` oracle. The
 * generic whole-file `merge` walk is retired: the `/update-gaia` skill
 * hand-walks the decision table (Step 7) and field-merges `package.json`
 * (7a) and `pnpm-workspace.yaml` (7b) by name, so no caller routes
 * `update merge`. These tests lock that surface: `merge` is unknown,
 * `merge-workspace` still routes.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {EXIT_CODES} from '../exit.js';
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

describe('update router', () => {
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
  });

  test('rejects retired `merge` subcommand as unknown', async () => {
    const exit = await run([
      'merge',
      '--baseline',
      'baseline',
      '--latest',
      'latest',
      '--manifest',
      'manifest.json',
    ]);

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);

    const err = JSON.parse(stdio.errors.join('').trim()) as {
      code: string;
      subcommand: string;
    };
    expect(err.code).toBe('unknown_subcommand');
    expect(err.subcommand).toBe('update merge');
  });

  test('still routes `merge-workspace`', async () => {
    const exit = await run(['--help']);

    expect(exit).toBe(EXIT_CODES.OK);

    const help = stdio.outputs.join('');
    expect(help).toContain('merge-workspace');
    // The generic per-manifest-class walk is gone from the help surface.
    expect(help).not.toContain('Three-way file compare per manifest class');
  });
});
