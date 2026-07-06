import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia-maintainer release bump`.
 */
import {execFileSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {aggregateBump, applyBump, classifyCommit, run} from './bump.js';
import type {CommandRunner} from './bump.js';

describe('classifyCommit', () => {
  test('feat: → minor', () => {
    expect(classifyCommit({body: '', subject: 'feat: add thing'})).toBe(
      'minor'
    );
    expect(classifyCommit({body: '', subject: 'feat(scope): add'})).toBe(
      'minor'
    );
  });

  test('fix:/docs:/etc → patch', () => {
    expect(classifyCommit({body: '', subject: 'fix: a bug'})).toBe('patch');
    expect(classifyCommit({body: '', subject: 'docs: typo'})).toBe('patch');
    expect(classifyCommit({body: '', subject: 'chore(deps): bump'})).toBe(
      'patch'
    );
    expect(classifyCommit({body: '', subject: 'refactor: clean'})).toBe(
      'patch'
    );
    expect(classifyCommit({body: '', subject: 'perf: speed'})).toBe('patch');
    expect(classifyCommit({body: '', subject: 'ci: pipeline'})).toBe('patch');
    expect(classifyCommit({body: '', subject: 'test: cover'})).toBe('patch');
    expect(classifyCommit({body: '', subject: 'style: lint'})).toBe('patch');
  });

  test('! suffix → major', () => {
    expect(classifyCommit({body: '', subject: 'feat!: drop API'})).toBe(
      'major'
    );
    expect(classifyCommit({body: '', subject: 'fix(scope)!: rename'})).toBe(
      'major'
    );
  });

  test('BREAKING CHANGE in body → major', () => {
    expect(
      classifyCommit({
        body: 'BREAKING CHANGE: removed thing',
        subject: 'feat: x',
      })
    ).toBe('major');
  });

  test('non-conventional → null', () => {
    expect(classifyCommit({body: '', subject: 'random commit'})).toBeNull();
    expect(classifyCommit({body: '', subject: 'merged something'})).toBeNull();
  });
});

describe('aggregateBump', () => {
  test('highest severity wins', () => {
    expect(
      aggregateBump([
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'feat: b'},
        {body: '', subject: 'docs: c'},
      ])
    ).toBe('minor');
  });

  test('breaking trumps everything', () => {
    expect(
      aggregateBump([
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'feat!: b'},
        {body: '', subject: 'feat: c'},
      ])
    ).toBe('major');
  });

  test('all-patch → patch', () => {
    expect(
      aggregateBump([
        {body: '', subject: 'fix: a'},
        {body: '', subject: 'chore: b'},
      ])
    ).toBe('patch');
  });

  test('no recognizable commits → null', () => {
    expect(
      aggregateBump([
        {body: '', subject: 'random'},
        {body: '', subject: 'merge'},
      ])
    ).toBeNull();
  });
});

describe('applyBump', () => {
  test('major resets minor and patch', () => {
    expect(applyBump('1.2.3', 'major')).toBe('2.0.0');
  });

  test('minor resets patch', () => {
    expect(applyBump('1.2.3', 'minor')).toBe('1.3.0');
  });

  test('patch increments patch', () => {
    expect(applyBump('1.2.3', 'patch')).toBe('1.2.4');
  });

  test('throws on non-semver', () => {
    expect(() => applyBump('not.a.version', 'patch')).toThrow();
    expect(() => applyBump('1.2', 'patch')).toThrow();
  });
});

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const setupSandbox = (currentVersion: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-bump-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify({name: 'gaia', version: currentVersion}, null, 2)}\n`,
    'utf8'
  );
  writeFileSync(
    path.join(root, '.gaia', 'VERSION'),
    `${currentVersion}\n`,
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

const okResult = (stdout = ''): SpawnSyncReturns<string> => ({
  output: ['', stdout, ''] as never,
  pid: 0,
  signal: null,
  status: 0,
  stderr: '',
  stdout,
});

const failResult = (status: number): SpawnSyncReturns<string> => ({
  output: ['', '', ''] as never,
  pid: 0,
  signal: null,
  status,
  stderr: '',
  stdout: '',
});

const buildLogOutput = (
  commits: {body?: string; subject: string}[]
): string => {
  const RECORD_SEPARATOR = '---END-COMMIT---';

  return commits
    .map(
      (commit) =>
        `${commit.subject}\n${commit.body ?? ''}\n${RECORD_SEPARATOR}\n`
    )
    .join('');
};

const buildRunner =
  (commits: {body?: string; subject: string}[]): CommandRunner =>
  (command, args) => {
    if (command === 'git' && args[0] === 'describe') {
      // Simulate "no tag yet"
      return failResult(128);
    }

    if (command === 'git' && args[0] === 'log') {
      return okResult(buildLogOutput(commits));
    }

    return okResult('');
  };

describe('release bump CLI', () => {
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

  test('proposes minor bump when feat: present, without writing', () => {
    sandbox = setupSandbox('1.2.3');
    const runner = buildRunner([
      {subject: 'feat: add thing'},
      {subject: 'fix: bug'},
    ]);

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('v1.2.3 -> v1.3.0 (minor)');

    // Did NOT write
    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {version: string};
    expect(pkg.version).toBe('1.2.3');
  });

  test('--auto applies a patch bump', () => {
    sandbox = setupSandbox('1.0.0');
    const runner = buildRunner([{subject: 'fix: a'}, {subject: 'docs: b'}]);

    const exit = run(['--auto'], {cwd: sandbox.root, runner});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('1.0.1');

    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {version: string};
    expect(pkg.version).toBe('1.0.1');

    const versionFile = readFileSync(
      path.join(sandbox.root, '.gaia', 'VERSION'),
      'utf8'
    );
    expect(versionFile).toBe('1.0.1\n');
  });

  test('--auto refuses major without confirmation', () => {
    sandbox = setupSandbox('1.0.0');
    const runner = buildRunner([{subject: 'feat!: rip out X'}]);

    const exit = run(['--auto'], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('refusing --auto');

    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {version: string};
    expect(pkg.version).toBe('1.0.0');
  });

  test('exits 1 when no commits', () => {
    sandbox = setupSandbox('1.0.0');
    const runner = buildRunner([]);

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('no commits since last tag');
  });

  test('exits 1 when no conventional-commit prefixes', () => {
    sandbox = setupSandbox('1.0.0');
    const runner = buildRunner([{subject: 'random non-conventional commit'}]);

    const exit = run([], {cwd: sandbox.root, runner});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('no conventional-commit prefixes');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox('1.0.0');
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
