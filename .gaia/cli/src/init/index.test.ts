import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia init` router, and specifically for its target guard.
 *
 * The guard answers "where is this running", which every per-step precondition
 * leaves unasked: they all ask only whether their own rewrite is doable.
 */
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {readState} from './util/state.js';
import {run} from './index.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-router-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

/** A tree that looks like an adopter scaffold: GAIA present, sources absent. */
const makeScaffold = (root: string): void => {
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(path.join(root, '.gaia', 'manifest.json'), '{"files":{}}\n');
};

/** A tree that looks like the GAIA template source: `.gaia/cli/src` present. */
const makeTemplateSource = (root: string): void => {
  makeScaffold(root);
  mkdirSync(path.join(root, '.gaia', 'cli', 'src'), {recursive: true});
};

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

const errorCodes = (errors: readonly string[]): string[] =>
  errors.map((line) => (JSON.parse(line) as {code: string}).code);

describe('gaia init router target guard', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
  });

  test('refuses a tree that is not a GAIA project', async () => {
    const exitCode = await run(['rename', '--title', 'X', '--kebab', 'x'], {
      cwd: sandbox.root,
    });

    expect(exitCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(errorCodes(stdio.errors)).toStrictEqual(['not_a_gaia_project']);
  });

  test('names the resolved path it refused, so the operator can see which tree it read', async () => {
    await run(['rename', '--title', 'X', '--kebab', 'x'], {
      cwd: sandbox.root,
    });

    expect(stdio.errors.join('')).toContain(sandbox.root);
  });

  test('refuses the GAIA template source even though it is a GAIA project', async () => {
    makeTemplateSource(sandbox.root);

    const exitCode = await run(['rename', '--title', 'X', '--kebab', 'x'], {
      cwd: sandbox.root,
    });

    expect(exitCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(errorCodes(stdio.errors)).toStrictEqual(['gaia_template_source']);
  });

  test('guards every step, not only rename', async () => {
    const steps = [
      'strip-branding',
      'configure-i18n',
      'rename',
      'wire-statusline',
      'bootstrap-env',
      'configure-automation',
      'finalize',
      'resume',
    ];

    const codes: string[][] = [];

    // Sequentially: the stderr capture is one shared buffer, so concurrent
    // runs would interleave and the per-step windows would not be readable.
    for (const step of steps) {
      const before = stdio.errors.length;

      await run([step], {cwd: sandbox.root});
      codes.push(errorCodes(stdio.errors.slice(before)));
    }

    expect(codes).toStrictEqual(steps.map(() => ['not_a_gaia_project']));
  });

  test('lets a real scaffold through to the step', async () => {
    makeScaffold(sandbox.root);

    const exitCode = await run(['bootstrap-env'], {cwd: sandbox.root});

    expect(exitCode).toBe(EXIT_CODES.OK);
    expect(stdio.errors).toStrictEqual([]);
    expect(readState(sandbox.root).completed_steps).toContain('bootstrap-env');
  });

  test('hands the step the same path it guarded', async () => {
    makeScaffold(sandbox.root);
    writeFileSync(path.join(sandbox.root, '.env.example'), 'A=1\n');

    await run(['bootstrap-env'], {cwd: sandbox.root});

    // The guard validates one path and the step writes to another unless the
    // router hands its resolved cwd down. Assert the write landed in the tree
    // that was guarded, not in the process's ambient directory.
    expect(existsSync(path.join(sandbox.root, '.env'))).toBe(true);
  });

  test('leaves the router help path unguarded', async () => {
    const exitCode = await run([], {cwd: sandbox.root});

    expect(exitCode).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia init <subcommand>');
    expect(stdio.errors).toStrictEqual([]);
  });

  test('leaves a per-step help request unguarded', async () => {
    const exitCode = await run(['rename', '--help'], {cwd: sandbox.root});

    expect(exitCode).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toContain('Usage: gaia init rename');
    expect(stdio.errors).toStrictEqual([]);
  });

  test('still reports an unknown subcommand as unknown, not as a bad target', async () => {
    const exitCode = await run(['bogus'], {cwd: sandbox.root});

    expect(exitCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(errorCodes(stdio.errors)).toStrictEqual(['unknown_subcommand']);
  });
});
