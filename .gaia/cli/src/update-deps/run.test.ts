import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  classifyBucket,
  classifyKind,
  computeUpdates,
  resolveGroup,
  run,
  type PnpmRunner,
} from './run.js';
import {saveDeclines} from './declines.js';
import {resolveGroupMembers} from './groups.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writePackageJson: (contents: Record<string, unknown>) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-update-deps-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
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

/**
 * Map from package name to its latest version, used to fake `pnpm view <name> version`.
 * Use `null` to simulate a registry failure (package not found / network error).
 */
type FakeViewVersions = Record<string, string | null>;

/**
 * Map from package name to its `version -> ISO publish time` table, used to
 * fake `pnpm view <name> time --json`. Use `null` to simulate a registry
 * failure (the release-age cooldown then records the package as unresolved).
 */
type FakeViewTimes = Record<string, Record<string, string> | null>;

const makePnpmRunner = (
  fakeOutdated: FakeOutdated,
  eslintVersions?: readonly string[],
  fakeViewVersions?: FakeViewVersions,
  fakeViewTimes?: FakeViewTimes,
  fakeVersionLists?: Record<string, readonly string[]>
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

    // pnpm view <name> versions --json; used by the ESLint cap and the config
    // version-hold cap. `eslint` falls back to the `eslintVersions` arg.
    if (args[0] === 'view' && args[2] === 'versions') {
      const pkgName = args[1] as string;
      const list =
        fakeVersionLists?.[pkgName] ??
        (pkgName === 'eslint' ? eslintVersions : undefined) ??
        [];

      return {status: 0, stderr: '', stdout: JSON.stringify(list)};
    }

    // pnpm view <name> time --json; used by the release-age cooldown.
    if (args[0] === 'view' && args[2] === 'time' && args[3] === '--json') {
      const pkgName = args[1] as string;
      const times = fakeViewTimes?.[pkgName];

      if (times === null) {
        return {status: 1, stderr: `E404 Not found: ${pkgName}`, stdout: ''};
      }

      if (times !== undefined) {
        return {status: 0, stderr: '', stdout: JSON.stringify(times)};
      }
    }

    // pnpm view <name> version; used to fetch latest for sibling expansion
    if (args[0] === 'view' && args[2] === 'version' && args.length === 3) {
      const pkgName = args[1] as string;
      const resolved = fakeViewVersions?.[pkgName];

      if (resolved === null) {
        return {status: 1, stderr: `E404 Not found: ${pkgName}`, stdout: ''};
      }

      if (resolved !== undefined) {
        return {status: 0, stderr: '', stdout: `${resolved}\n`};
      }
    }

    return {
      status: 1,
      stderr: `unexpected args: ${args.join(' ')}`,
      stdout: '',
    };
  };
};

describe('update-deps run: version classification', () => {
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

describe('update-deps run: group resolution', () => {
  test('react-router family maps to react-router group', () => {
    expect(resolveGroup('react-router')).toBe('react-router');
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
    expect(resolveGroup('@fortawesome/fontawesome-svg-core')).toBe(
      'fontawesome'
    );
    expect(resolveGroup('@fortawesome/free-solid-svg-icons')).toBe(
      'fontawesome'
    );
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

describe('update-deps run: computeUpdates', () => {
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
        '@react-router/serve': '^6.30.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        'react-router': {current: '6.30.0', latest: '7.0.0', wanted: '6.30.0'},
        '@react-router/serve': {
          current: '6.30.0',
          latest: '7.0.0',
          wanted: '6.30.0',
        },
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

  test('config hold: held package with no in-ceiling upgrade is dropped as held', () => {
    // vite is held at the 8.0 line; latest 8.1.0 is above it and the highest
    // 8.0.x (8.0.16) equals the installed version → dropped, held at current.
    sandbox.writePackageJson({
      dependencies: {vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '8.0'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {vite: {current: '8.0.16', latest: '8.1.0', wanted: '8.1.0'}},
        undefined,
        undefined,
        undefined,
        {vite: ['8.0.15', '8.0.16', '8.1.0', '8.1.2']}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toEqual([]);
    expect(result.total_count).toBe(0);
    expect(result.skipped).toEqual([
      {current: '8.0.16', latest: '8.1.0', name: 'vite', reason: 'held'},
    ]);
  });

  test('config hold: an in-ceiling patch above current is offered, capped', () => {
    // Held at 8.0; an 8.0.17 patch exists above the installed 8.0.16 → offered
    // at 8.0.17, never the 8.1.x line.
    sandbox.writePackageJson({
      dependencies: {vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '8.0'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {vite: {current: '8.0.16', latest: '8.1.0', wanted: '8.1.0'}},
        undefined,
        undefined,
        undefined,
        {vite: ['8.0.16', '8.0.17', '8.1.0']}
      ),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.name).toBe('vite');
    expect(result.wave_a[0]?.latest).toBe('8.0.17');
    expect(result.wave_a[0]?.kind).toBe('patch');
  });

  test('config hold: latest already on the ceiling line passes through', () => {
    // Held at 8.0 but latest is 8.0.17 (already on-line) → offered normally,
    // no version-list lookup needed.
    sandbox.writePackageJson({
      dependencies: {vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '8.0'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner({
        vite: {current: '8.0.16', latest: '8.0.17', wanted: '8.0.17'},
      }),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.latest).toBe('8.0.17');
  });

  test('config hold: an exact-version ceiling freezes the package', () => {
    // Ceiling "8.0.16" pins all three segments → nothing above 8.0.16 matches,
    // so the package is frozen (dropped as held) even against an 8.0.17 patch.
    sandbox.writePackageJson({
      dependencies: {vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '8.0.16'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {vite: {current: '8.0.16', latest: '8.0.17', wanted: '8.0.17'}},
        undefined,
        undefined,
        undefined,
        {vite: ['8.0.16', '8.0.17']}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.skipped).toEqual([
      {current: '8.0.16', latest: '8.0.17', name: 'vite', reason: 'held'},
    ]);
  });

  test('config hold: an unsatisfiable ceiling fails closed (held, not bumped)', () => {
    // Ceiling "7" matches no published version → drop rather than let vite jump
    // above the ceiling to 8.1.0.
    sandbox.writePackageJson({
      dependencies: {vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '7'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {vite: {current: '8.0.16', latest: '8.1.0', wanted: '8.1.0'}},
        undefined,
        undefined,
        undefined,
        {vite: ['8.0.16', '8.1.0']}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.skipped).toEqual([
      {current: '8.0.16', latest: '8.1.0', name: 'vite', reason: 'held'},
    ]);
  });

  test('config hold: an unheld package is untouched', () => {
    sandbox.writePackageJson({
      dependencies: {foo: '^1.2.3', vite: '8.0.16'},
      gaia: {updateDepsHold: {vite: '8.0'}},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
          vite: {current: '8.0.16', latest: '8.1.0', wanted: '8.1.0'},
        },
        undefined,
        undefined,
        undefined,
        {vite: ['8.0.16', '8.1.0']}
      ),
    });

    // foo flows through; vite is held out.
    expect(result.wave_a.map((entry) => entry.name)).toEqual(['foo']);
    expect(result.skipped).toEqual([
      {current: '8.0.16', latest: '8.1.0', name: 'vite', reason: 'held'},
    ]);
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

  test('sibling expansion: non-outdated group member included in wave_b when trigger is major', () => {
    // react is outdated (major), react-dom is up-to-date in pnpm outdated
    // but both are in package.json → react-dom must be pulled in via pnpm view
    sandbox.writePackageJson({
      dependencies: {
        react: '^18.0.0',
        'react-dom': '^18.2.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          react: {current: '18.0.0', latest: '19.0.0', wanted: '18.0.0'},
        },
        undefined,
        {'react-dom': '19.0.0'}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toHaveLength(1);
    const group = result.wave_b[0];
    expect(group?.group).toBe('react');
    expect(group?.packages).toHaveLength(2);
    const reactPkg = group?.packages.find((p) => p.name === 'react');
    const reactDomPkg = group?.packages.find((p) => p.name === 'react-dom');
    expect(reactPkg?.latest).toBe('19.0.0');
    expect(reactPkg?.kind).toBe('major');
    expect(reactDomPkg?.latest).toBe('19.0.0');
    expect(reactDomPkg?.current).toBe('18.2.0');
    // sibling with equal current/latest gets kind: "patch" as no-op default
    // (react-dom 18.2.0 → 19.0.0 is actually a major, verify that too)
    expect(reactDomPkg?.kind).toBe('major');
    expect(reactDomPkg?.wanted).toBe('19.0.0');
  });

  test('sibling expansion: non-outdated group member included in wave_a when trigger is minor', () => {
    // react-router is minor bump, @react-router/serve is current but present in pkg.json
    sandbox.writePackageJson({
      dependencies: {
        'react-router': '^7.0.0',
        '@react-router/serve': '^7.0.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          'react-router': {current: '7.0.0', latest: '7.1.0', wanted: '7.1.0'},
        },
        undefined,
        {'@react-router/serve': '7.1.0'}
      ),
    });

    expect(result.wave_b).toEqual([]);
    expect(result.wave_a).toHaveLength(2);
    const rrd = result.wave_a.find((e) => e.name === '@react-router/serve');
    expect(rrd).toBeDefined();
    expect(rrd?.latest).toBe('7.1.0');
    expect(rrd?.current).toBe('7.0.0');
    expect(rrd?.kind).toBe('minor');
    expect(rrd?.group).toBe('react-router');
  });

  test('sibling expansion: up-to-date sibling (current === latest) still included', () => {
    // @react-router/serve is truly up-to-date after fetch; must still be included
    sandbox.writePackageJson({
      dependencies: {
        'react-router': '^7.1.0',
        '@react-router/serve': '^7.1.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          'react-router': {current: '7.1.0', latest: '7.2.0', wanted: '7.2.0'},
        },
        undefined,
        {'@react-router/serve': '7.2.0'}
      ),
    });

    expect(result.wave_a).toHaveLength(2);
    const rrd = result.wave_a.find((e) => e.name === '@react-router/serve');
    expect(rrd).toBeDefined();
    // current 7.1.0 vs latest 7.2.0 → minor
    expect(rrd?.kind).toBe('minor');
  });

  test('sibling expansion: up-to-date sibling where current === latest gets kind: "patch"', () => {
    // @react-router/serve is exactly on latest after fetch → no-op, kind: "patch"
    sandbox.writePackageJson({
      dependencies: {
        'react-router': '^7.1.0',
        '@react-router/serve': '^7.2.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          'react-router': {current: '7.1.0', latest: '7.2.0', wanted: '7.2.0'},
        },
        undefined,
        {'@react-router/serve': '7.2.0'}
      ),
    });

    expect(result.wave_a).toHaveLength(2);
    const rrd = result.wave_a.find((e) => e.name === '@react-router/serve');
    expect(rrd).toBeDefined();
    // current 7.2.0 vs latest 7.2.0 → equal, kind: "patch" as no-op default
    expect(rrd?.kind).toBe('patch');
    expect(rrd?.current).toBe('7.2.0');
    expect(rrd?.latest).toBe('7.2.0');
    expect(rrd?.wanted).toBe('7.2.0');
  });

  test('sibling expansion: registry failure adds sibling to skipped with registry-unresolved', () => {
    sandbox.writePackageJson({
      dependencies: {
        react: '^18.0.0',
        'react-dom': '^18.2.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          react: {current: '18.0.0', latest: '19.0.0', wanted: '18.0.0'},
        },
        undefined,
        {'react-dom': null} // simulate registry failure
      ),
    });

    // react-dom skipped, react group still emitted with just react
    expect(result.wave_b).toHaveLength(1);
    expect(result.wave_b[0]?.packages).toHaveLength(1);
    expect(result.wave_b[0]?.packages[0]?.name).toBe('react');
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]?.name).toBe('react-dom');
    expect(result.skipped[0]?.reason).toBe('registry-unresolved');
  });

  test('sibling expansion: group with zero outdated members is omitted entirely', () => {
    // Only foo (singleton) is outdated; react group has no outdated members
    // → react group must not appear in any wave, even if react and react-dom
    //   are present in package.json
    sandbox.writePackageJson({
      dependencies: {
        foo: '^1.2.3',
        react: '^19.0.0',
        'react-dom': '^19.0.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
        },
        undefined,
        // These would never be called; react group has no outdated trigger
        {}
      ),
    });

    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.name).toBe('foo');
    expect(result.wave_b).toEqual([]);
    expect(result.skipped).toEqual([]);
  });

  test('sibling expansion: prefix-based group member in package.json is pulled in', () => {
    // @storybook/react is in package.json but not flagged outdated.
    // storybook (exact) IS flagged outdated → pull in @storybook/react via pnpm view.
    sandbox.writePackageJson({
      devDependencies: {
        storybook: '^8.0.0',
        '@storybook/react': '^8.0.0',
      },
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {
          storybook: {current: '8.0.0', latest: '9.0.0', wanted: '8.0.0'},
        },
        undefined,
        {'@storybook/react': '9.0.0'}
      ),
    });

    expect(result.wave_b).toHaveLength(1);
    const group = result.wave_b[0];
    expect(group?.group).toBe('storybook');
    expect(group?.packages).toHaveLength(2);
    const sbReact = group?.packages.find((p) => p.name === '@storybook/react');
    expect(sbReact?.latest).toBe('9.0.0');
    expect(sbReact?.kind).toBe('major');
  });

  test('sibling expansion: current version comes from node_modules, not the spec', () => {
    sandbox.writePackageJson({
      devDependencies: {
        storybook: '^8.0.0',
        '@storybook/react': '^8.0.0',
      },
    });
    // @storybook/react is already on 9.0.0 in node_modules even though the
    // package.json spec still floors at ^8.0.0.
    mkdirSync(path.join(sandbox.root, 'node_modules', '@storybook', 'react'), {
      recursive: true,
    });
    writeFileSync(
      path.join(
        sandbox.root,
        'node_modules',
        '@storybook',
        'react',
        'package.json'
      ),
      JSON.stringify({name: '@storybook/react', version: '9.0.0'}),
      'utf8'
    );

    const result = computeUpdates({
      cwd: sandbox.root,
      pnpmRunner: makePnpmRunner(
        {storybook: {current: '8.0.0', latest: '9.0.0', wanted: '8.0.0'}},
        undefined,
        {'@storybook/react': '9.0.0'}
      ),
    });

    const sbReact = result.wave_b[0]?.packages.find(
      (p) => p.name === '@storybook/react'
    );
    expect(sbReact?.current).toBe('9.0.0');
    // current === latest → classified patch (no-op), not major.
    expect(sbReact?.kind).toBe('patch');
  });
});

describe('update-deps run: group membership', () => {
  test('resolveGroupMembers returns all package.json members for an exact-name group', () => {
    const allNames = ['react', 'react-dom', '@types/react', 'lodash'];
    expect(resolveGroupMembers('react', allNames)).toEqual(
      expect.arrayContaining(['react', 'react-dom', '@types/react'])
    );
    expect(resolveGroupMembers('react', allNames)).not.toContain('lodash');
  });

  test('resolveGroupMembers handles prefix-based groups', () => {
    const allNames = [
      'storybook',
      '@storybook/react',
      '@storybook/addon-essentials',
      'react',
    ];
    const members = resolveGroupMembers('storybook', allNames);
    expect(members).toContain('storybook');
    expect(members).toContain('@storybook/react');
    expect(members).toContain('@storybook/addon-essentials');
    expect(members).not.toContain('react');
  });

  test('resolveGroupMembers returns empty array for singleton groups', () => {
    expect(
      resolveGroupMembers('singleton:lodash', ['lodash', 'react'])
    ).toEqual([]);
  });
});

describe('update-deps run: CLI', () => {
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
      snoozed: unknown[];
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
    expect(parsed.snoozed).toEqual([]);
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

describe('update-deps run: release-age cooldown', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  // minimumReleaseAge: 10080 (7 days). With NOW at 2026-06-02T00:00Z the
  // cooldown cutoff is 2026-05-26T00:00Z: anything published on/before it is
  // "aged", anything after is "too young".
  const NOW = (): Date => new Date('2026-06-02T00:00:00.000Z');
  const ANCIENT = '2025-01-01T00:00:00.000Z';
  const AGED = '2026-05-20T00:00:00.000Z';
  const TOO_YOUNG = '2026-05-30T00:00:00.000Z';

  const writeWorkspace = (root: string, minutes: number): void => {
    writeFileSync(
      path.join(root, 'pnpm-workspace.yaml'),
      `minimumReleaseAge: ${minutes}\n`,
      'utf8'
    );
  };

  test('caps latest to the newest aged version at or below latest', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'}},
        undefined,
        undefined,
        {
          foo: {
            '1.0.0': ANCIENT,
            '1.1.0': AGED,
            '1.2.0': AGED,
            '1.3.0': TOO_YOUNG,
          },
        }
      ),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.name).toBe('foo');
    expect(result.wave_a[0]?.latest).toBe('1.2.0');
    expect(result.wave_a[0]?.kind).toBe('minor');
    // wanted is clamped so it never exceeds the capped latest.
    expect(result.wave_a[0]?.wanted).toBe('1.2.0');
  });

  test('skips a package when every upgrade is younger than the cooldown', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'}},
        undefined,
        undefined,
        {foo: {'1.0.0': ANCIENT, '1.3.0': TOO_YOUNG}}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.wave_b).toEqual([]);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]?.name).toBe('foo');
    expect(result.skipped[0]?.reason).toBe('release-age-cooldown');
    expect(result.skipped[0]?.latest).toBe('1.3.0');
  });

  test('leaves latest untouched when it is already old enough', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {foo: {current: '1.0.0', latest: '1.2.0', wanted: '1.2.0'}},
        undefined,
        undefined,
        {foo: {'1.0.0': ANCIENT, '1.2.0': AGED}}
      ),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.latest).toBe('1.2.0');
  });

  test('ignores prerelease versions when capping', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'}},
        undefined,
        undefined,
        {
          foo: {
            '1.0.0': ANCIENT,
            '1.2.0': AGED,
            '1.3.0-beta.1': AGED,
            '1.3.0': TOO_YOUNG,
          },
        }
      ),
    });

    // 1.3.0-beta.1 is aged and at/below latest, but prereleases are excluded.
    expect(result.wave_a[0]?.latest).toBe('1.2.0');
  });

  test('disabled when pnpm-workspace.yaml has no minimumReleaseAge', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    // No pnpm-workspace.yaml written. The runner provides no time table, so a
    // stray cooldown lookup would fall through to "unexpected args" and skip
    // foo; this asserts the cooldown never runs.

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(1);
    expect(result.wave_a[0]?.latest).toBe('1.3.0');
  });

  test('minimumReleaseAge of 0 disables the cooldown', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 0);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a[0]?.latest).toBe('1.3.0');
  });

  test('records release-age-unresolved when the time lookup fails', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.0.0'}});
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {foo: {current: '1.0.0', latest: '1.3.0', wanted: '1.3.0'}},
        undefined,
        undefined,
        {foo: null}
      ),
    });

    expect(result.wave_a).toEqual([]);
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]?.name).toBe('foo');
    expect(result.skipped[0]?.reason).toBe('release-age-unresolved');
  });

  test('caps a sibling-expanded version too', () => {
    sandbox.writePackageJson({
      dependencies: {'react-router': '^7.0.0', '@react-router/serve': '^7.0.0'},
    });
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {'react-router': {current: '7.0.0', latest: '7.2.0', wanted: '7.2.0'}},
        undefined,
        {'@react-router/serve': '7.3.0'},
        {
          'react-router': {'7.0.0': ANCIENT, '7.2.0': AGED},
          '@react-router/serve': {
            '7.0.0': ANCIENT,
            '7.2.0': AGED,
            '7.3.0': TOO_YOUNG,
          },
        }
      ),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(2);
    const rrd = result.wave_a.find((e) => e.name === '@react-router/serve');
    expect(rrd?.latest).toBe('7.2.0');
    expect(rrd?.kind).toBe('minor');
  });

  test('an up-to-date sibling (current === latest) is still included', () => {
    sandbox.writePackageJson({
      dependencies: {'react-router': '^7.1.0', '@react-router/serve': '^7.2.0'},
    });
    writeWorkspace(sandbox.root, 10080);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner(
        {'react-router': {current: '7.1.0', latest: '7.2.0', wanted: '7.2.0'}},
        undefined,
        {'@react-router/serve': '7.2.0'},
        // No time table for @react-router/serve: it is up to date, so the
        // cooldown must not attempt a lookup for it.
        {'react-router': {'7.1.0': ANCIENT, '7.2.0': AGED}}
      ),
    });

    expect(result.skipped).toEqual([]);
    expect(result.wave_a).toHaveLength(2);
    const rrd = result.wave_a.find((e) => e.name === '@react-router/serve');
    expect(rrd).toBeDefined();
    expect(rrd?.kind).toBe('patch');
    expect(rrd?.latest).toBe('7.2.0');
  });
});

describe('update-deps run: preview payload fields', () => {
  let sandbox: Sandbox;
  const NOW = (): Date => new Date('2026-06-11T18:00:00.000Z');

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('classifyBucket buckets a pre-1.0 current as nonsemver', () => {
    expect(classifyBucket('0.4.0', '0.5.0')).toBe('nonsemver');
    expect(classifyBucket('0.4.0', '1.0.0')).toBe('nonsemver');
  });

  test('classifyBucket falls back to patch/minor/major at or above 1.0', () => {
    expect(classifyBucket('1.2.3', '1.2.4')).toBe('patch');
    expect(classifyBucket('1.2.3', '1.3.0')).toBe('minor');
    expect(classifyBucket('1.2.3', '2.0.0')).toBe('major');
  });

  test('each wave entry carries a display bucket; 0.x is nonsemver', () => {
    sandbox.writePackageJson({
      dependencies: {foo: '^1.2.3', tiny: '^0.4.0'},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
        tiny: {current: '0.4.0', latest: '0.5.0', wanted: '0.5.0'},
      }),
    });

    const foo = result.wave_a.find((entry) => entry.name === 'foo');
    const tiny = result.wave_a.find((entry) => entry.name === 'tiny');
    expect(foo?.bucket).toBe('minor');
    expect(tiny?.bucket).toBe('nonsemver');
  });

  test('total_count counts every package; actionable_count equals it with no ledger', () => {
    sandbox.writePackageJson({
      dependencies: {bar: '^4.5.0', foo: '^1.2.3'},
    });

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        bar: {current: '4.5.0', latest: '4.5.1', wanted: '4.5.1'},
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(result.total_count).toBe(2);
    expect(result.actionable_count).toBe(2);
  });

  test('a snoozed group drops out of actionable_count but not total_count', () => {
    sandbox.writePackageJson({
      dependencies: {
        foo: '^1.2.3',
        'react-router': '^7.1.0',
        '@react-router/serve': '^7.1.0',
      },
    });
    saveDeclines(sandbox.root, [
      {
        declined_at: NOW().toISOString(),
        group: 'react-router',
        targets: {'react-router': '7.2.0', '@react-router/serve': '7.2.0'},
      },
    ]);

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
        'react-router': {current: '7.1.0', latest: '7.2.0', wanted: '7.2.0'},
        '@react-router/serve': {
          current: '7.1.0',
          latest: '7.2.0',
          wanted: '7.2.0',
        },
      }),
    });

    // 3 outstanding (foo + 2 react-router); the snoozed react-router group
    // leaves only foo actionable.
    expect(result.total_count).toBe(3);
    expect(result.actionable_count).toBe(1);
    // The snoozed group is surfaced per-group for the preview to default-skip.
    expect(result.snoozed).toEqual([
      {
        group: 'react-router',
        resurfaces_at: new Date(
          NOW().getTime() + 14 * 24 * 60 * 60 * 1000
        ).toISOString(),
        snoozed_at: NOW().toISOString(),
        targets: {'@react-router/serve': '7.2.0', 'react-router': '7.2.0'},
      },
    ]);
  });

  test('snoozed is empty when the ledger has no matching active decline', () => {
    sandbox.writePackageJson({dependencies: {foo: '^1.2.3'}});

    const result = computeUpdates({
      cwd: sandbox.root,
      now: NOW,
      pnpmRunner: makePnpmRunner({
        foo: {current: '1.2.3', latest: '1.3.0', wanted: '1.3.0'},
      }),
    });

    expect(result.snoozed).toEqual([]);
  });
});
