/**
 * Mostly drives the resume orchestrator with stubbed step runners so we can
 * assert ordering + skip-if-complete + argv reconstruction without spinning
 * up real filesystem fixtures for each step.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {argvFromStepArgs, run} from './resume.js';
import {STEP_ORDER, writeState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-resume-'));

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
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

describe('argvFromStepArgs', () => {
  test('reconstructs strip-branding argv', () => {
    expect(argvFromStepArgs('strip-branding', {title: 'Hello'})).toEqual([
      '--title',
      'Hello',
    ]);
    expect(argvFromStepArgs('strip-branding', {})).toBeNull();
  });

  test('reconstructs configure-i18n argv', () => {
    expect(
      argvFromStepArgs('configure-i18n', {locales: ['en', 'es'], strip: false})
    ).toEqual(['--locales', 'en,es', '--strip', 'false']);
    expect(argvFromStepArgs('configure-i18n', {locales: 'bad'})).toBeNull();
  });

  test('reconstructs rename argv', () => {
    expect(
      argvFromStepArgs('rename', {kebab: 'hello-world', title: 'Hello World'})
    ).toEqual(['--title', 'Hello World', '--kebab', 'hello-world']);
  });

  test('reconstructs wire-statusline argv', () => {
    expect(argvFromStepArgs('wire-statusline', {mode: 'project'})).toEqual([
      '--mode',
      'project',
    ]);
  });

  test('reconstructs write-project-config argv', () => {
    expect(
      argvFromStepArgs('write-project-config', {sandbox_recommended: true})
    ).toEqual(['--sandbox-recommended', 'true']);
    expect(
      argvFromStepArgs('write-project-config', {
        isolation_policy: 'always-worktree',
        sandbox_recommended: false,
      })
    ).toEqual([
      '--sandbox-recommended',
      'false',
      '--isolation-policy',
      'always-worktree',
    ]);
  });

  test('write-project-config argv is null when its saved args cannot replay', () => {
    expect(argvFromStepArgs('write-project-config', {})).toBeNull();
    expect(argvFromStepArgs('write-project-config', undefined)).toBeNull();
    expect(
      argvFromStepArgs('write-project-config', {sandbox_recommended: 'true'})
    ).toBeNull();
    expect(
      argvFromStepArgs('write-project-config', {
        isolation_policy: 7,
        sandbox_recommended: true,
      })
    ).toBeNull();
  });

  test('STEP_ORDER keeps seven steps with write-project-config at index 5', () => {
    expect(STEP_ORDER).toHaveLength(7);
    expect(STEP_ORDER.indexOf('write-project-config')).toBe(5);
    expect(STEP_ORDER as readonly string[]).not.toContain(
      ['configure', 'automation'].join('-')
    );
  });

  test('finalize requires no args', () => {
    expect(argvFromStepArgs('finalize', undefined)).toEqual([]);
  });

  test('returns null when saved args are missing for non-finalize steps', () => {
    expect(argvFromStepArgs('strip-branding', undefined)).toBeNull();
  });
});

describe('init resume', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('--from-step 3 skips steps 1-2 if marked complete; runs from step 3', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: ['strip-branding', 'configure-i18n'],
      step_args: {
        'configure-i18n': {locales: ['en'], strip: false},
        rename: {kebab: 'hello', title: 'Hello'},
        'strip-branding': {title: 'Hello'},
        'wire-statusline': {mode: 'skip'},
        'write-project-config': {sandbox_recommended: true},
      },
    });

    const calls: {argv: readonly string[]; step: string}[] = [];

    const stub = (step: string) => (argv: readonly string[]) => {
      calls.push({argv, step});

      return 0;
    };

    const exit = await run(['--from-step', '3'], {
      cwd: sandbox.root,
      runners: {
        'configure-i18n': stub('configure-i18n'),
        finalize: stub('finalize'),
        rename: stub('rename'),
        'strip-branding': stub('strip-branding'),
        'wire-statusline': stub('wire-statusline'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);

    // configure-i18n + strip-branding are step 1 and 2, and ALSO marked
    // complete. They should not run regardless of skip-vs-from-step.
    expect(calls.map((c) => c.step)).toEqual([
      'rename',
      'wire-statusline',
      'write-project-config',
      'finalize',
    ]);
    expect(calls[0]?.argv).toEqual(['--title', 'Hello', '--kebab', 'hello']);
  });

  test('default --from-step 1 still skips already-complete steps', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: ['strip-branding'],
      step_args: {
        'configure-i18n': {locales: ['en'], strip: true},
        rename: {kebab: 'x', title: 'X'},
        'strip-branding': {title: 'X'},
        'wire-statusline': {mode: 'skip'},
        'write-project-config': {sandbox_recommended: false},
      },
    });

    const ran: string[] = [];

    const stub = (step: string) => () => {
      ran.push(step);

      return 0;
    };

    const exit = await run([], {
      cwd: sandbox.root,
      runners: {
        'configure-i18n': stub('configure-i18n'),
        finalize: stub('finalize'),
        rename: stub('rename'),
        'strip-branding': stub('strip-branding'),
        'wire-statusline': stub('wire-statusline'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);
    expect(ran).not.toContain('strip-branding');
    expect(ran).toContain('configure-i18n');
    expect(ran).toContain('write-project-config');
    expect(ran).toContain('finalize');
  });

  test('exit 1 when a step has no saved args', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {completed_steps: [], step_args: {}});

    const exit = await run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('missing_step_args');
  });

  test('propagates non-zero exit from a step runner', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [],
      step_args: {'strip-branding': {title: 'X'}},
    });

    const exit = await run([], {
      cwd: sandbox.root,
      runners: {
        'strip-branding': () => 2,
      },
    });
    expect(exit).toBe(2);
  });

  test('--from-step out of range exits 1', async () => {
    sandbox = setupSandbox();
    const exit = await run(['--from-step', '99'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--from-step must be');
  });

  test('--from-step 8 is refused because only seven steps exist', async () => {
    sandbox = setupSandbox();
    const exit = await run(['--from-step', '8'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--from-step must be');
  });

  test('--from-step 6 replays write-project-config from its saved args', async () => {
    sandbox = setupSandbox();
    writeState(sandbox.root, {
      completed_steps: [],
      step_args: {
        'write-project-config': {
          isolation_policy: 'prefer-branch',
          sandbox_recommended: true,
        },
      },
    });

    const calls: {argv: readonly string[]; step: string}[] = [];

    const stub = (step: string) => (argv: readonly string[]) => {
      calls.push({argv, step});

      return 0;
    };

    const exit = await run(['--from-step', '6'], {
      cwd: sandbox.root,
      runners: {
        finalize: stub('finalize'),
        'write-project-config': stub('write-project-config'),
      },
    });
    expect(exit).toBe(0);
    expect(calls.map((call) => call.step)).toEqual([
      'write-project-config',
      'finalize',
    ]);
    expect(calls[0]?.argv).toEqual([
      '--sandbox-recommended',
      'true',
      '--isolation-policy',
      'prefer-branch',
    ]);
  });

  test('--from-step 0 exits 1', async () => {
    sandbox = setupSandbox();
    const exit = await run(['--from-step', '0'], {cwd: sandbox.root});
    expect(exit).toBe(1);
  });
});
