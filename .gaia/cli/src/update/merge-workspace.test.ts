import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia update merge-workspace`.
 *
 * Strategy: write three temporary `pnpm-workspace.yaml` files (baseline /
 * latest / current), run the handler, and assert the JSON verdict report.
 * The command is a read-only verdict oracle: it never writes the YAML, so
 * there are no on-disk side effects to assert (the `/update-gaia` skill
 * applies `applied[]` via the Edit tool to preserve comments and order).
 */
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './merge-workspace.js';
import type {WorkspaceMergeReport} from './merge-workspace.js';

type Sandbox = {
  baselinePath: string;
  cleanup: () => void;
  currentPath: string;
  latestPath: string;
  root: string;
  write: (which: 'baseline' | 'current' | 'latest', contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-merge-workspace-'));
  const baselinePath = path.join(root, 'baseline.yaml');
  const latestPath = path.join(root, 'latest.yaml');
  const currentPath = path.join(root, 'current.yaml');

  return {
    baselinePath,
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    currentPath,
    latestPath,
    root,
    write: (which, contents): void => {
      const target =
        which === 'baseline' ? baselinePath
        : which === 'latest' ? latestPath
        : currentPath;
      writeFileSync(target, contents, 'utf8');
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

const parseJson = (outputs: readonly string[]): WorkspaceMergeReport =>
  JSON.parse(outputs.join('').trim()) as WorkspaceMergeReport;

const argv = (sandbox: Sandbox): string[] => [
  '--baseline',
  sandbox.baselinePath,
  '--latest',
  sandbox.latestPath,
  '--current',
  sandbox.currentPath,
  '--json',
];

describe('update merge-workspace', () => {
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

  test('version-only release: managed keys identical → all buckets empty', () => {
    const yaml = 'minimumReleaseAge: 10080\ntrustPolicy: no-downgrade\n';
    sandbox.write('baseline', yaml);
    sandbox.write('latest', yaml);
    sandbox.write('current', yaml);

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('scalar apply: GAIA bumped, adopter undrifted → applied with latest value', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: 10_080,
        baseline: 10_080,
        key: 'minimumReleaseAge',
        kind: 'key',
        latest: 20_160,
      },
    ]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('scalar conflict: GAIA changed, adopter re-pinned independently → conflict, adopter kept', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 5000\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([
      {
        adopter: 5000,
        baseline: 10_080,
        key: 'minimumReleaseAge',
        kind: 'key',
        latest: 20_160,
      },
    ]);
  });

  test('GAIA-added managed key → suggestion (added), never auto-inserted', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write(
      'latest',
      'minimumReleaseAge: 10080\nstrictPeerDependencies: false\n'
    );
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.suggestions).toEqual([
      {
        key: 'strictPeerDependencies',
        kind: 'key',
        latest: false,
        reason: 'added',
      },
    ]);
  });

  test('adopter removed a key GAIA then changed → suggestion (removed-then-changed), never re-added', () => {
    sandbox.write('baseline', 'trustPolicy: no-downgrade\n');
    sandbox.write('latest', 'trustPolicy: strict\n');
    sandbox.write('current', 'savePrefix: ""\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    // savePrefix in current only (not in B or L) is never visited.
    expect(report.suggestions).toEqual([
      {
        baseline: 'no-downgrade',
        key: 'trustPolicy',
        kind: 'key',
        latest: 'strict',
        reason: 'removed-then-changed',
      },
    ]);
  });

  test('overrides map: per-entry apply, adopter-added entry untouched', () => {
    sandbox.write(
      'baseline',
      "overrides:\n  'qs': '>=6.15.2'\n  'ws': '>=8.20.1'\n"
    );
    sandbox.write(
      'latest',
      "overrides:\n  'qs': '>=6.16.0'\n  'ws': '>=8.20.1'\n"
    );
    sandbox.write(
      'current',
      "overrides:\n  'qs': '>=6.15.2'\n  'ws': '>=8.20.1'\n  'my-dep': '1.0.0'\n"
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    // qs applied; ws unchanged (noop); my-dep adopter-only → never visited.
    expect(report.applied).toEqual([
      {
        adopter: '>=6.15.2',
        baseline: '>=6.15.2',
        key: 'qs',
        kind: 'entry',
        latest: '>=6.16.0',
        section: 'overrides',
      },
    ]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('overrides map: adopter re-pinned an entry → conflict, adopter kept', () => {
    sandbox.write('baseline', "overrides:\n  'qs': '>=6.15.2'\n");
    sandbox.write('latest', "overrides:\n  'qs': '>=6.16.0'\n");
    sandbox.write('current', "overrides:\n  'qs': '>=6.99.0'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toEqual([
      {
        adopter: '>=6.99.0',
        baseline: '>=6.15.2',
        key: 'qs',
        kind: 'entry',
        latest: '>=6.16.0',
        section: 'overrides',
      },
    ]);
  });

  test('allowBuilds map: boolean flip applied; GAIA-added build → suggestion', () => {
    sandbox.write('baseline', 'allowBuilds:\n  core-js-pure: true\n');
    sandbox.write(
      'latest',
      'allowBuilds:\n  core-js-pure: false\n  msw: true\n'
    );
    sandbox.write('current', 'allowBuilds:\n  core-js-pure: true\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: true,
        baseline: true,
        key: 'core-js-pure',
        kind: 'entry',
        latest: false,
        section: 'allowBuilds',
      },
    ]);
    expect(report.suggestions).toEqual([
      {
        key: 'msw',
        kind: 'entry',
        latest: true,
        reason: 'added',
        section: 'allowBuilds',
      },
    ]);
  });

  test('list key: whole-value apply when adopter undrifted', () => {
    sandbox.write('baseline', "publicHoistPattern:\n  - '*stylelint*'\n");
    sandbox.write(
      'latest',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'prettier-plugin-*'\n"
    );
    sandbox.write('current', "publicHoistPattern:\n  - '*stylelint*'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: ['*stylelint*'],
        baseline: ['*stylelint*'],
        key: 'publicHoistPattern',
        kind: 'key',
        latest: ['*stylelint*', 'prettier-plugin-*'],
      },
    ]);
  });

  test('list key: adopter extended the list → conflict (whole-value drift)', () => {
    sandbox.write('baseline', "publicHoistPattern:\n  - '*stylelint*'\n");
    sandbox.write(
      'latest',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'prettier-plugin-*'\n"
    );
    sandbox.write(
      'current',
      "publicHoistPattern:\n  - '*stylelint*'\n  - 'my-tool-*'\n"
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toEqual([
      {
        adopter: ['*stylelint*', 'my-tool-*'],
        baseline: ['*stylelint*'],
        key: 'publicHoistPattern',
        kind: 'key',
        latest: ['*stylelint*', 'prettier-plugin-*'],
      },
    ]);
  });

  test('managed section absent in baseline and latest: adopter overrides untouched', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 10080\n');
    sandbox.write('current', "overrides:\n  'foo': '1.0.0'\n");

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('non-managed top-level key is ignored entirely', () => {
    sandbox.write('baseline', 'nodeLinker: hoisted\n');
    sandbox.write('latest', 'nodeLinker: isolated\n');
    sandbox.write('current', 'nodeLinker: hoisted\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('malformed adopter YAML → non-zero exit with structured error', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'overrides:\n  qs: [unterminated\n');

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);

    const stderr = stdio.errors.join('');
    expect(stderr).toContain('workspace_parse_failed');
  });

  test('missing file → non-zero exit with structured error', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    // current never written.

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);

    const stderr = stdio.errors.join('');
    expect(stderr).toContain('workspace_file_missing');
  });

  test('human output (no --json) prints counts', () => {
    sandbox.write('baseline', 'minimumReleaseAge: 10080\n');
    sandbox.write('latest', 'minimumReleaseAge: 20160\n');
    sandbox.write('current', 'minimumReleaseAge: 10080\n');

    const exit = run([
      '--baseline',
      sandbox.baselinePath,
      '--latest',
      sandbox.latestPath,
      '--current',
      sandbox.currentPath,
    ]);
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('Applied:');
    expect(out).toContain('1');
  });

  test('--help prints usage and exits 0', () => {
    const exit = run(['--help']);
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('merge-workspace');
  });
});
