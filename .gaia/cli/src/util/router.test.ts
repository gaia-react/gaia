import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {createSubcommandRouter, runWhenInvokedDirectly} from './router.js';

const HELP_TEXT = 'Usage: fake <subcommand>\n';

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
const originalArgv = [...process.argv];
const originalExitCode = process.exitCode;

beforeEach(() => {
  stdio = captureStdio();
});

afterEach(() => {
  stdio.restore();
  process.argv = [...originalArgv];
  process.exitCode = originalExitCode;
});

const readStderrPayload = (): Record<string, unknown> =>
  JSON.parse(stdio.errors.join('').trim().split('\n').at(-1) ?? '{}') as Record<
    string,
    unknown
  >;

describe('createSubcommandRouter', () => {
  const handler = vi.fn();
  const route = createSubcommandRouter({
    handlers: {known: handler, silent: () => undefined},
    helpText: HELP_TEXT,
  });

  beforeEach(() => {
    handler.mockReset();
  });

  test.each(['--help', '-h', 'help'])(
    '%s prints the help text and returns OK',
    async (token) => {
      await expect(route([token])).resolves.toBe(EXIT_CODES.OK);
      expect(stdio.outputs.join('')).toBe(HELP_TEXT);
      expect(stdio.errors).toHaveLength(0);
    }
  );

  test('no argument prints the help text and returns OK', async () => {
    await expect(route([])).resolves.toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe(HELP_TEXT);
  });

  test('a known subcommand receives the rest of argv and its result propagates', async () => {
    handler.mockResolvedValue(7);

    await expect(route(['known', '--x', 'y'])).resolves.toBe(7);
    expect(handler).toHaveBeenCalledWith(['--x', 'y']);
  });

  test('a handler returning undefined maps to OK', async () => {
    await expect(route(['silent'])).resolves.toBe(EXIT_CODES.OK);
  });

  test('an unknown subcommand is refused with a structured error', async () => {
    await expect(route(['bogus'])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(readStderrPayload()).toMatchObject({
      code: 'unknown_subcommand',
      subcommand: 'bogus',
    });
  });

  test.each(['toString', 'constructor', '__proto__'])(
    'the inherited key %s is an unknown subcommand',
    async (key) => {
      await expect(route([key])).resolves.toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(readStderrPayload()).toMatchObject({
        code: 'unknown_subcommand',
        subcommand: key,
      });
    }
  );
});

describe('runWhenInvokedDirectly', () => {
  let scratch: string;
  let entryFile: string;

  beforeEach(() => {
    // The router compares against the realpath, and macOS temp dirs are symlinks.
    scratch = realpathSync(mkdtempSync(path.join(tmpdir(), 'router-')));
    entryFile = path.join(scratch, 'entry.js');
    writeFileSync(entryFile, '');
  });

  afterEach(() => {
    rmSync(scratch, {force: true, recursive: true});
  });

  test('does not call run when the module is not the invoked file', async () => {
    const run = vi.fn().mockResolvedValue(0);

    process.argv = ['node', entryFile];
    await runWhenInvokedDirectly('file:///somewhere/else.js', run);

    expect(run).not.toHaveBeenCalled();
  });

  test('does not call run when argv has no entry path', async () => {
    const run = vi.fn().mockResolvedValue(0);

    process.argv = ['node'];
    await runWhenInvokedDirectly(pathToFileURL(entryFile).href, run);

    expect(run).not.toHaveBeenCalled();
  });

  test('sets process.exitCode from run when invoked directly', async () => {
    const run = vi.fn().mockResolvedValue(5);

    process.argv = ['node', entryFile, 'a', 'b'];
    await runWhenInvokedDirectly(pathToFileURL(entryFile).href, run);

    expect(run).toHaveBeenCalledWith(['a', 'b']);
    expect(process.exitCode).toBe(5);
  });

  test('a thrown error becomes cli_internal_error and an unknown-subcommand exit code', async () => {
    const run = vi.fn().mockRejectedValue(new Error('boom'));

    process.argv = ['node', entryFile];
    await runWhenInvokedDirectly(pathToFileURL(entryFile).href, run);

    expect(readStderrPayload()).toMatchObject({
      code: 'cli_internal_error',
      message: 'boom',
    });
    expect(process.exitCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });
});
