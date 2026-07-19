import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia-maintainer release manifest` CLI's flag grammar: argv
 * parsing, unknown-flag rejection, and flag-combination validation, all
 * exercised through `run(...)`.
 *
 * The check/emit execution tests (manifest content, `--check` reporting, the
 * answer gate) live in `manifest-cli.test.ts`.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './manifest-cli.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
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

describe('run (CLI)', () => {
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

  test('rejects unknown flags', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '0.0.1\n',
    });

    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test.each([
    'toString',
    'valueOf',
    'constructor',
    'hasOwnProperty',
    '__proto__',
  ])('rejects the prototype-member token %s as an unknown flag', (token) => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '0.0.1\n',
    });

    const exit = run([token], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});

describe('run --check', () => {
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

  test('--check is incompatible with --out', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
    });

    const exit = run(['--check', '--out', 'foo.json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('incompatible');
  });

  test('--json requires --check', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
    });

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--json requires --check');
  });
});

const GENERATED_AT = '2026-05-07T00:00:00.000Z';

describe('run (answer gate)', () => {
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

  const runGate = (argv: readonly string[]): number =>
    run(argv, {cwd: sandbox.root, generatedAt: GENERATED_AT});

  test.each([
    ['--check with --ship', ['--check', '--ship', 'app/new.ts']],
    ['--check with --allow-undecided', ['--check', '--allow-undecided']],
    [
      '--check with --withhold',
      [
        '--check',
        '--withhold',
        'app/new.ts',
        '--category',
        '1',
        '--reason',
        'r',
      ],
    ],
    ['--category with no open --withhold', ['--category', '1']],
    ['--reason with no open --withhold', ['--reason', 'r']],
    [
      'a --withhold with no --category',
      ['--withhold', 'app/new.ts', '--reason', 'r'],
    ],
    [
      'a --withhold with no --reason',
      ['--withhold', 'app/new.ts', '--category', '1'],
    ],
    [
      'two --category on one --withhold',
      [
        '--withhold',
        'app/new.ts',
        '--category',
        '1',
        '--category',
        '2',
        '--reason',
        'r',
      ],
    ],
    [
      'a non-numeric --category',
      ['--withhold', 'app/new.ts', '--category', 'one', '--reason', 'r'],
    ],
  ])('rejects %s', (_label, argv) => {
    expect(runGate(argv)).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });
});
