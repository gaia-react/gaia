import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  classifyKind,
  computeUpdates,
  resolveGroup,
  run,
  type PnpmRunner,
} from './run.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writePackageJson: (contents: Record<string, unknown>) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-update-deps-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {cwd: root});
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writePackageJson: (contents) => {
      writeFileSync(
        path.join(root, 'package.json'),
        JSON.stringify(contents, null, 2),
        'utf8'
      );
    },
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

type FakeOutdated = Record<
  string,
  {current: string; latest: string; wanted: string; dependencyType?: string}
>;

const makePnpmRunner = (
  fakeOutdated: FakeOutdated,
  eslintVersions?: readonly string[]
): PnpmRunner => {
  return (args) => {
    if (args[0] === 'outdated' && args.includes('--json')) {
      // pnpm outdated exits 1 when packages are outdated; mirror that.
      return {
        status: Object.keys(fakeOutdated).length === 0 ? 0 : 1,
        stderr: '',
        stdout: JSON.stringify(fakeOutdated),
      };
    }

    if (args[0] === 'view' && args[1] === 'eslint') {
      return {
        status: 0,
        stderr: '',
        stdout: JSON.stringify(eslintVersions ?? []),
      };
    }

    return {status: 1, stderr: `unexpected args: ${args.join(' ')}`, stdout: ''};
  };
};

describe('update-deps run — version classification', () => {
  test('classifyKind returns major when leading integer differs', () => {
    expect(classifyKind('1.2.3', '2.0.0')).toBe('major');
    expect(classifyKind('6.30.0', '7.0.0')).toBe('major');
  });

  test('classifyKind returns minor when major matches but minor differs', () => {
    expect(classifyKind('1.2.3', '1.3.0')).toBe('minor');
  });

  test('classifyKind returns patch when only patch differs', () => {
    expect(classifyKind('1.2.3', '1.2.5')).toBe('patch');
  });

  test('classifyKind handles caret/tilde prefixes on current', () => {
    expect(classifyKind('^1.2.3', '1.3.0')).toBe('minor');
    expect(classifyKind('~1.2.3', '2.0.0')).toBe('major');
  });

  test('classifyKind treats 0.x bumps by leading-segment rule', () => {
    // Per spec: compare leading integers. 0→0 same major.
    expect(classifyKind('0.1.0', '0.2.0')).toBe('minor');
    expect(classifyKind('0.1.0', '1.0.0')).toBe('major');
  });
});

describe('update-deps run — group resolution', () => {
  test('react-router family maps to react-router group', () => {
    expect(resolveGroup('react-router')).toBe('react-router');
    expect(resolveGroup('react-router-dom')).toBe('react-router');
    expect(resolveGroup('@react-router/dev')).toBe('react-router');
    expect(resolveGroup('@react-router/serve')).toBe('react-router');
  });

  test('@types/react family maps to react group', () => {
    expect(resolveGroup('react')).toBe('react');
    expect(resolveGroup('@types/react')).toBe('react');
  });

  test('@storybook/* prefix maps to storybook group', () => {
    expect(resolveGroup('@storybook/react')).toBe('storybook');
    expect(resolveGroup('@storybook/addon-essentials')).toBe('storybook');
    expect(resolveGroup('eslint-plugin-storybook')).toBe('storybook');
  });

  test('eslint-config-* and eslint-plugin-* map to eslint group', () => {
    expect(resolveGroup('eslint')).toBe('eslint');
    expect(resolveGroup('eslint-config-airbnb')).toBe('eslint');
    expect(resolveGroup('eslint-plugin-react')).toBe('eslint');
  });

  test('@fortawesome/* prefix maps to fontawesome group', () => {
    expect(resolveGroup('@fortawesome/fontawesome-svg-core')).toBe('fontawesome');
    expect(resolveGroup('@fortawesome/free-solid-svg-icons')).toBe('fontawesome');
  });

  test('unknown package falls back to singleton:<name>', () => {
    expect(resolveGroup('lodash')).toBe('singleton:lodash');
  });

  test('eslint-config-prettier wins for prettier group (more specific)', () => {
    // prettier group lists eslint-config-prettier and eslint-plugin-prettier.
    // These must beat the eslint-config-* / eslint-plugin-* eslint-group rule.
    expect(resolveGroup('eslint-config-prettier')).toBe('prettier');
    expect(resolveGroup('eslint-plugin-prettier')).toBe('prettier');
  });

  test('msw-storybook-addon prefers storybook group over msw', () => {
    // The SKILL lists msw-storybook-addon under both storybook and msw.
    // We pick storybook (the more specific addon scope).
    expect(resolveGroup('msw-storybook-addon')).toBe('storybook');
  });
});

describe('update-deps run — computeUpdates', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('all minor/patch land in wave_a as singletons by default', () => {
    sandbox.writePackageJson({
      dependencies: {
        foo: '^1.2.3',
        bar: '~4.5.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        bar: {current: '4.5.0', latest: '4.5.1', wanted: '4.5.1'},
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(result.wave_b).toEqual([]);
    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(2);
    const foo = result.wave_a.find((entry) => entry.name === 'foo');
    expect(foo).toBeDefined();
    expect(foo?.group).toBe('singleton:foo');
    expect(foo?.kind).toBe('minor');
    expect(foo?.is_pinned).toBe(false);
    const bar = result.wave_a.find((entry) => entry.name === 'bar');
    expect(bar?.kind).toBe('patch');
  });

  test('pinned package (no caret/tilde) reports is_pinned=true', () => {
    sandbox.writePackageJson({
      dependencies: {
        foo: '1.2.3',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    const foo = result.wave_a.find((entry) => entry.name === 'foo');
    expect(foo?.is_pinned).toBe(true);
  });

  test('any major bump in a group lands in wave_b with all members from outdated', () => {
    sandbox.writePackageJson({
      dependencies: {
        'react-router': '^6.30.0',
        'react-router-dom': '^6.30.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        'react-router': {current: '6.30.0', latest: '7.0.0', wanted: '6.30.0'},
        'react-router-dom': {current: '6.30.0', latest: '7.0.0', wanted: '6.30.0'},
      }),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toHaveLength(1);
    expect(result.wave_b[0]?.group).toBe('react-router');
    expect(result.wave_b[0]?.packages).toHaveLength(2);
  });

  test('mixed wave: a major-bumped group is wave_b; unrelated patch is wave_a', () => {
    sandbox.writePackageJson({
      dependencies: {
        foo: '^1.2.3',
        react: '^18.0.0',
        'react-dom': '^18.0.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.2.5', wanted: '1.2.5'},
        react: {current: '18.0.0', latest: '19.0.0', wanted: '18.0.0'},
        'react-dom': {current: '18.0.0', latest: '19.0.0', wanted: '18.0.0'},
      }),
    });

    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.name).toBe('foo');
    expect(result.wave_b).toHaveLength(1);
    expect(result.wave_b[0]?.group).toBe('react');
  });

  test('wave_b group includes a minor-bumped sibling when another sibling is major', () => {
    // Per SKILL Phase 2: when ANY member of a group is outdated/major, all
    // outdated members move together as one Wave B group.
    sandbox.writePackageJson({
      dependencies: {
        react: '^18.0.0',
        'react-dom': '^18.2.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        react: {current: '18.0.0', latest: '19.0.0', wanted: '18.0.0'},
        'react-dom': {current: '18.2.0', latest: '18.3.0', wanted: '18.3.0'},
      }),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toHaveLength(1);
    expect(result.wave_b[0]?.packages).toHaveLength(2);
  });

  test('eslint cap: latest 10.x rewritten to highest 9.x available', () => {
    sandbox.writePackageJson({
      dependencies: {
        eslint: '^9.20.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {eslint: {current: '9.20.0', latest: '10.0.0', wanted: '9.20.0'}},
        ['9.18.0', '9.19.0', '9.21.0', '9.22.0', '10.0.0']
      ),
    });

    // 9.22.0 is highest 9.x available, so latest is rewritten and it lands in wave_a.
    expect(result.wave_b).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.latest).toBe('9.22.0');
    expect(result.wave_a[0]?.kind).toBe('minor');
  });

  test('eslint cap: already on highest 9.x → entry dropped entirely', () => {
    sandbox.writePackageJson({
      dependencies: {
        eslint: '^9.22.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {eslint: {current: '9.22.0', latest: '10.0.0', wanted: '9.22.0'}},
        ['9.18.0', '9.22.0', '10.0.0']
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toEqual([]);
    expect(result.skipped).toEqual([]);
  });

  test('emits an empty payload when nothing is outdated', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.2.3'}});

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({}),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toEqual([]);
    expect(result.skipped).toEqual([]);
  });
});

describe('update-deps run — CLI', () => {
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

  test('--emit-updates writes the schema to disk and exits 0', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.2.3'}});
    const outPath = path.join(sandbox.root, 'updates.json');
    const fixedNow = new Date('2026-05-10T12:34:56.000Z');

    const exit = run(['--emit-updates', outPath], {
      cwd: sandbox.root,
      now: () => fixedNow,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(exit).toBe(0);
    const written = readFileSync(outPath, 'utf8');
    const parsed = JSON.parse(written) as {
      generated_at: string;
      schema_version: number;
      skipped: unknown[];
      wave_a: {group: string; kind: string; name: string}[];
      wave_b: unknown[];
    };
    expect(parsed.schema_version).toBe(1);
    expect(parsed.generated_at).toBe('2026-05-10T12:34:56.000Z');
    expect(parsed.wave_a).toHaveLength(1);
    expect(parsed.wave_a[0]?.name).toBe('foo');
    expect(parsed.wave_a[0]?.kind).toBe('minor');
    expect(parsed.wave_b).toEqual([]);
    expect(parsed.skipped).toEqual([]);
  });

  test('--emit-updates creates parent directories on demand', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.2.3'}});
    const outPath = path.join(sandbox.root, 'a', 'b', 'updates.json');

    const exit = run(['--emit-updates', outPath], {
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(exit).toBe(0);
    expect(() => readFileSync(outPath, 'utf8')).not.toThrow();
  });

  test('rejects when --emit-updates is missing a value', () => {
    const exit = run(['--emit-updates'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--emit-updates');
  });

  test('rejects when --emit-updates is omitted entirely', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--emit-updates');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--emit-updates', '/tmp/x.json', '--bogus'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Usage: gaia update-deps run');
  });
});
