import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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
import {EXIT_CODES} from '../exit.js';
import {projectConfigPath} from '../schemas/project-config.js';
import {readState} from './util/state.js';
import {run} from './write-project-config.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-write-project-'));

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

// Built at runtime so the retired config file name never lands as a literal.
const retiredConfigPath = (root: string): string =>
  path.join(root, '.gaia', ['automation', 'json'].join('.'));

describe('init write-project-config', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('creates .gaia/project.json with both keys and records the step with its args', () => {
    const exit = run(
      [
        '--sandbox-recommended',
        'true',
        '--isolation-policy',
        'always-worktree',
      ],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    const raw = readFileSync(projectConfigPath(sandbox.root), 'utf8');
    expect(raw.endsWith('\n')).toBe(true);
    expect(JSON.parse(raw)).toEqual({
      isolation_policy: 'always-worktree',
      sandbox_recommended: true,
      version: 1,
    });
    expect(existsSync(retiredConfigPath(sandbox.root))).toBe(false);

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('write-project-config');
    expect(state.step_args['write-project-config']).toEqual({
      isolation_policy: 'always-worktree',
      sandbox_recommended: true,
    });
  });

  test('omitting --isolation-policy leaves the key absent', () => {
    const exit = run(['--sandbox-recommended', 'false'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = JSON.parse(
      readFileSync(projectConfigPath(sandbox.root), 'utf8')
    ) as Record<string, unknown>;
    expect(written).toEqual({sandbox_recommended: false, version: 1});
    expect('isolation_policy' in written).toBe(false);
    expect(readState(sandbox.root).step_args['write-project-config']).toEqual({
      sandbox_recommended: false,
    });
  });

  test('omitting --isolation-policy keeps a value already on file, and unknown keys survive', () => {
    const first = run(
      ['--sandbox-recommended', 'true', '--isolation-policy', 'prefer-branch'],
      {cwd: sandbox.root}
    );
    expect(first).toBe(EXIT_CODES.OK);

    const target = projectConfigPath(sandbox.root);
    const seeded = JSON.parse(readFileSync(target, 'utf8')) as Record<
      string,
      unknown
    >;
    writeFileSync(
      target,
      JSON.stringify({...seeded, some_future_key: 'x'}),
      'utf8'
    );

    const second = run(['--sandbox-recommended', 'false'], {cwd: sandbox.root});
    expect(second).toBe(EXIT_CODES.OK);

    const written = JSON.parse(readFileSync(target, 'utf8')) as Record<
      string,
      unknown
    >;
    expect(written.isolation_policy).toBe('prefer-branch');
    expect(written.sandbox_recommended).toBe(false);
    expect(written.some_future_key).toBe('x');
  });

  test('--sandbox-recommended maybe is refused with a structured error and writes nothing', () => {
    const exit = run(['--sandbox-recommended', 'maybe'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain(
      '--sandbox-recommended must be one of: true, false'
    );
    expect(stdio.errors.join('')).toContain('"code":"invalid_arguments"');
    expect(stdio.errors.join('')).toContain(
      '"subcommand":"init write-project-config"'
    );
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
    expect(
      existsSync(path.join(sandbox.root, '.gaia', 'init-state.json'))
    ).toBe(false);
  });

  test('--isolation-policy with an unknown value is refused and writes nothing', () => {
    const exit = run(
      ['--sandbox-recommended', 'true', '--isolation-policy', 'bogus'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain(
      '--isolation-policy must be one of: always-worktree, prefer-branch, prefer-worktree'
    );
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('--sandbox-recommended is required', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain(
      '--sandbox-recommended is required'
    );
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('a repeated flag and an unknown flag are refused', () => {
    const twice = run(
      ['--sandbox-recommended', 'true', '--sandbox-recommended', 'false'],
      {cwd: sandbox.root}
    );
    expect(twice).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain(
      '--sandbox-recommended specified twice'
    );

    const unknown = run(['--sandbox-recommended', 'true', '--bogus', 'x'], {
      cwd: sandbox.root,
    });
    expect(unknown).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain('unknown flag: --bogus');
    expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
  });

  test('a malformed existing file is refused with a structured error naming it, and left unchanged', () => {
    const malformed = '{not json';
    mkdirSync(path.dirname(projectConfigPath(sandbox.root)), {recursive: true});
    writeFileSync(projectConfigPath(sandbox.root), malformed, 'utf8');

    const exit = run(['--sandbox-recommended', 'true'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    expect(stdio.errors.join('')).toContain('"code":"config_malformed"');
    expect(stdio.errors.join('')).toContain('project.json');
    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      malformed
    );
    expect(
      existsSync(path.join(sandbox.root, '.gaia', 'init-state.json'))
    ).toBe(false);
  });

  test('idempotent: re-running with the same flags writes byte-identical content', () => {
    const args = ['--sandbox-recommended', 'true'];

    expect(run(args, {cwd: sandbox.root})).toBe(EXIT_CODES.OK);
    const firstContent = readFileSync(projectConfigPath(sandbox.root), 'utf8');

    expect(run(args, {cwd: sandbox.root})).toBe(EXIT_CODES.OK);
    expect(readFileSync(projectConfigPath(sandbox.root), 'utf8')).toBe(
      firstContent
    );

    const count = readState(sandbox.root).completed_steps.filter(
      (step) => step === 'write-project-config'
    ).length;
    expect(count).toBe(1);
  });

  test.each(['--help', '-h', 'help'])(
    '%s exits 0 with usage and writes nothing',
    (token) => {
      const exit = run([token], {cwd: sandbox.root});
      expect(exit).toBe(EXIT_CODES.OK);
      expect(stdio.outputs.join('')).toContain(
        'Usage: gaia init write-project-config'
      );
      expect(existsSync(projectConfigPath(sandbox.root))).toBe(false);
    }
  );
});
