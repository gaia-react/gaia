/**
 * Tests for `gaia init finalize`.
 */
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {pruneInterceptInit, run} from './finalize.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const buildSettings = (extraExpansionEntries: unknown[] = []) => ({
  env: {EXAMPLE: '1'},
  hooks: {
    SessionStart: [
      {matcher: 'startup', hooks: [{command: 'other.sh', type: 'command'}]},
    ],
    UserPromptExpansion: [
      {
        hooks: [{command: '.claude/hooks/intercept-init.sh', type: 'command'}],
        matcher: 'init',
      },
      ...extraExpansionEntries,
    ],
  },
  permissions: {allow: [], deny: []},
});

const setupSandbox = (extraExpansionEntries: unknown[] = []): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-finalize-'));
  mkdirSync(path.join(root, '.claude', 'hooks'), {recursive: true});
  mkdirSync(path.join(root, '.claude', 'commands'), {recursive: true});
  writeFileSync(
    path.join(root, '.claude', 'hooks', 'intercept-init.sh'),
    '#!/bin/bash\necho intercept\n',
    'utf8'
  );
  writeFileSync(
    path.join(root, '.claude', 'commands', 'gaia-init.md'),
    '# gaia-init\n',
    'utf8'
  );
  writeFileSync(
    path.join(root, '.claude', 'settings.json'),
    `${JSON.stringify(buildSettings(extraExpansionEntries), null, 2)}\n`,
    'utf8'
  );

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

describe('pruneInterceptInit', () => {
  test('removes the intercept-init entry, preserves siblings', () => {
    const otherEntry = {
      hooks: [{command: 'other-hook.sh', type: 'command'}],
      matcher: 'preserve',
    };
    const result = pruneInterceptInit(buildSettings([otherEntry]));
    const hooks = result.hooks as Record<string, unknown>;
    expect(hooks.UserPromptExpansion).toEqual([otherEntry]);
    // SessionStart is preserved verbatim.
    expect(hooks.SessionStart).toEqual([
      {matcher: 'startup', hooks: [{command: 'other.sh', type: 'command'}]},
    ]);
  });

  test('removes the UserPromptExpansion key entirely if it would be empty', () => {
    const result = pruneInterceptInit(buildSettings()) as {
      hooks: Record<string, unknown>;
    };
    expect(result.hooks.UserPromptExpansion).toBeUndefined();
    // SessionStart untouched.
    expect(result.hooks.SessionStart).toBeDefined();
  });

  test('no-op when intercept-init is absent', () => {
    const source = {
      hooks: {
        UserPromptExpansion: [
          {hooks: [{command: 'other.sh', type: 'command'}], matcher: 'x'},
        ],
      },
    };
    const result = pruneInterceptInit(source);
    expect(result).toBe(source);
  });
});

describe('init finalize CLI', () => {
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

  test('removes intercept hook, prunes settings, deletes command, records state', () => {
    sandbox = setupSandbox();

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    expect(
      existsSync(
        path.join(sandbox.root, '.claude', 'hooks', 'intercept-init.sh')
      )
    ).toBe(false);
    expect(
      existsSync(path.join(sandbox.root, '.claude', 'commands', 'gaia-init.md'))
    ).toBe(false);

    const settings = JSON.parse(
      readFileSync(path.join(sandbox.root, '.claude', 'settings.json'), 'utf8')
    ) as {hooks: {UserPromptExpansion?: unknown}};
    expect(settings.hooks.UserPromptExpansion).toBeUndefined();

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('finalize');
  });

  test('idempotent: re-running is safe', () => {
    sandbox = setupSandbox();
    run([], {cwd: sandbox.root});
    const second = run([], {cwd: sandbox.root});
    expect(second).toBe(0);
  });

  test('exit 1 when settings.json is malformed', () => {
    sandbox = setupSandbox();
    writeFileSync(
      path.join(sandbox.root, '.claude', 'settings.json'),
      '{ broken',
      'utf8'
    );
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('settings_malformed');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox();
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
