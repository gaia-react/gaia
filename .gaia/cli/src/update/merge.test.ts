/**
 * Tests for `gaia update merge`.
 *
 * Strategy: stand up a sandbox directory with a working tree (`cwd/`),
 * a `baseline/` tarball-extract sibling, a `latest/` sibling, and a
 * synthetic manifest. Run the handler against each fixture and assert
 * both the JSON report and the on-disk side effects.
 *
 * `git merge-file` is exercised for real (no mock) — it ships with git,
 * which is already a hard dependency of the CLI.
 */
import {execFileSync} from 'node:child_process';
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
import {run, type UpdateMergeReport} from './merge.js';

type Sandbox = {
  cwd: string;
  baselineDir: string;
  latestDir: string;
  manifestPath: string;
  cleanup: () => void;
  /** Write a file into one of the trees ('cwd' | 'baseline' | 'latest'). */
  writeTree: (
    tree: 'baseline' | 'cwd' | 'latest',
    relative: string,
    contents: string
  ) => void;
  writeManifest: (
    files: Record<string, 'owned' | 'shared' | 'wiki-owned'>
  ) => void;
  readWorking: (relative: string) => string;
  readPatch: (relative: string) => string;
  hasWorking: (relative: string) => boolean;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-update-merge-'));
  const cwd = path.join(root, 'cwd');
  const baselineDir = path.join(root, 'baseline');
  const latestDir = path.join(root, 'latest');
  mkdirSync(cwd, {recursive: true});
  mkdirSync(baselineDir, {recursive: true});
  mkdirSync(latestDir, {recursive: true});

  return {
    baselineDir,
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    cwd,
    hasWorking: (relative: string): boolean =>
      existsSync(path.join(cwd, relative)),
    latestDir,
    manifestPath: path.join(root, 'manifest.json'),
    readPatch: (relative: string): string =>
      readFileSync(path.join(cwd, '.gaia-merge', `${relative}.patch`), 'utf8'),
    readWorking: (relative: string): string =>
      readFileSync(path.join(cwd, relative), 'utf8'),
    writeManifest: (files): void => {
      writeFileSync(
        path.join(root, 'manifest.json'),
        JSON.stringify({files, version: '1.0.0'}, null, 2),
        'utf8'
      );
    },
    writeTree: (tree, relative, contents): void => {
      const treeRoot =
        tree === 'cwd' ? cwd
        : tree === 'baseline' ? baselineDir
        : latestDir;
      const target = path.join(treeRoot, relative);
      mkdirSync(path.dirname(target), {recursive: true});
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

const parseJson = (outputs: readonly string[]): UpdateMergeReport =>
  JSON.parse(outputs.join('').trim()) as UpdateMergeReport;

const baseArgv = (sandbox: Sandbox): string[] => [
  '--baseline',
  sandbox.baselineDir,
  '--latest',
  sandbox.latestDir,
  '--manifest',
  sandbox.manifestPath,
  '--json',
];

describe('update merge', () => {
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

  test('clean overwrite: owned file pristine vs baseline → take latest', () => {
    sandbox.writeTree('cwd', 'app/foo.ts', 'export const X = 1;\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'export const X = 1;\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'export const X = 2;\n');
    sandbox.writeManifest({'app/foo.ts': 'owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.overwrite).toEqual(['app/foo.ts']);
    expect(report.skip).toEqual([]);
    expect(report.merge).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(sandbox.readWorking('app/foo.ts')).toBe('export const X = 2;\n');
  });

  test('skip: no drift anywhere → silent skip', () => {
    sandbox.writeTree('cwd', 'app/foo.ts', 'X\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'X\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'X\n');
    sandbox.writeManifest({'app/foo.ts': 'shared'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.skip).toEqual(['app/foo.ts']);
    expect(report.overwrite).toEqual([]);
    expect(report.merge).toEqual([]);
  });

  test('clean three-way merge: shared file with non-overlapping changes', () => {
    const baseline = 'line 1\nline 2\nline 3\nline 4\nline 5\n';
    // Adopter modified line 1.
    const current = 'line 1 ADOPTER\nline 2\nline 3\nline 4\nline 5\n';
    // Upstream modified line 5.
    const latest = 'line 1\nline 2\nline 3\nline 4\nline 5 UPSTREAM\n';
    sandbox.writeTree('cwd', 'shared.txt', current);
    sandbox.writeTree('baseline', 'shared.txt', baseline);
    sandbox.writeTree('latest', 'shared.txt', latest);
    sandbox.writeManifest({'shared.txt': 'shared'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.merge).toEqual(['shared.txt']);
    expect(report.conflicts).toEqual([]);

    const merged = sandbox.readWorking('shared.txt');
    expect(merged).toContain('line 1 ADOPTER');
    expect(merged).toContain('line 5 UPSTREAM');
  });

  test('three-way conflict: shared file with overlapping changes → patch', () => {
    const baseline = 'one line only\n';
    const current = 'adopter rewrote it\n';
    const latest = 'upstream rewrote it\n';
    sandbox.writeTree('cwd', 'shared.txt', current);
    sandbox.writeTree('baseline', 'shared.txt', baseline);
    sandbox.writeTree('latest', 'shared.txt', latest);
    sandbox.writeManifest({'shared.txt': 'shared'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0]?.path).toBe('shared.txt');
    expect(report.conflicts[0]?.class).toBe('shared');
    expect(report.conflicts[0]?.patch_path).toBe(
      '.gaia-merge/shared.txt.patch'
    );
    expect(report.merge).toEqual([]);
    // Working tree must be untouched on conflict.
    expect(sandbox.readWorking('shared.txt')).toBe(current);
    // Patch must be a unified-diff that git apply --check accepts.
    const patch = sandbox.readPatch('shared.txt');
    expect(patch).toContain('--- a/shared.txt');
    expect(patch).toContain('+++ b/shared.txt');
    expect(patch).toContain('-adopter rewrote it');
    expect(patch).toContain('+upstream rewrote it');
  });

  test('owned-class no-op: drift only on adopter side, latest unchanged', () => {
    sandbox.writeTree('cwd', 'app/foo.ts', 'adopter changed\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'pristine\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'pristine\n');
    sandbox.writeManifest({'app/foo.ts': 'owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.skip).toEqual(['app/foo.ts']);
    expect(report.conflicts).toEqual([]);
    expect(sandbox.readWorking('app/foo.ts')).toBe('adopter changed\n');
  });

  test('owned-class conflict: drift on both sides → emit patch, skip working tree', () => {
    sandbox.writeTree('cwd', 'app/foo.ts', 'adopter\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'pristine\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'upstream\n');
    sandbox.writeManifest({'app/foo.ts': 'owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0]?.class).toBe('owned');
    expect(report.conflicts[0]?.path).toBe('app/foo.ts');
    expect(report.overwrite).toEqual([]);
    expect(report.merge).toEqual([]);
    expect(sandbox.readWorking('app/foo.ts')).toBe('adopter\n');
    const patch = sandbox.readPatch('app/foo.ts');
    expect(patch).toContain('-adopter');
    expect(patch).toContain('+upstream');
  });

  test('manifest-missing path present in latest only → add[]', () => {
    sandbox.writeTree('latest', 'app/new-file.ts', 'export const NEW = 1;\n');
    sandbox.writeManifest({});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.add).toEqual(['app/new-file.ts']);
    expect(sandbox.readWorking('app/new-file.ts')).toBe(
      'export const NEW = 1;\n'
    );
  });

  test('manifest-missing path present in baseline only → delete[]', () => {
    sandbox.writeTree('cwd', 'app/old.ts', 'still here\n');
    sandbox.writeTree('baseline', 'app/old.ts', 'still here\n');
    sandbox.writeManifest({});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.delete).toEqual(['app/old.ts']);
    // Must NOT auto-delete.
    expect(sandbox.hasWorking('app/old.ts')).toBe(true);
  });

  test('renamed file: old path in baseline, new path in latest → add[] + delete[]', () => {
    // A command/skill rename drops the old path from the manifest and the
    // latest tarball and enters the new path into both. The adopter still
    // carries the old file. The merge decomposes this into an add for the
    // new path and a delete surfaced for the old one — no auto-removal.
    const body = 'command body\n';
    sandbox.writeTree('cwd', '.claude/commands/old-name.md', body);
    sandbox.writeTree('baseline', '.claude/commands/old-name.md', body);
    sandbox.writeTree('latest', '.claude/commands/new-name.md', body);
    sandbox.writeManifest({'.claude/commands/new-name.md': 'owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.add).toEqual(['.claude/commands/new-name.md']);
    expect(report.delete).toEqual(['.claude/commands/old-name.md']);
    expect(sandbox.readWorking('.claude/commands/new-name.md')).toBe(body);
    // Old file surfaced for the skill to confirm, never auto-removed.
    expect(sandbox.hasWorking('.claude/commands/old-name.md')).toBe(true);
  });

  test('malformed manifest exits 1 with structured error', () => {
    writeFileSync(sandbox.manifestPath, '{ this is not valid json', 'utf8');

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('manifest is not valid JSON');
  });

  test('manifest with unknown class exits 1', () => {
    sandbox.writeTree('latest', 'foo.ts', 'x\n');
    writeFileSync(
      sandbox.manifestPath,
      JSON.stringify({files: {'foo.ts': 'mystery'}}, null, 2),
      'utf8'
    );

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown class');
  });

  test('missing baseline directory exits 1', () => {
    sandbox.writeManifest({});
    const exit = run(
      [
        '--baseline',
        path.join(sandbox.cwd, 'does-not-exist'),
        '--latest',
        sandbox.latestDir,
        '--manifest',
        sandbox.manifestPath,
        '--json',
      ],
      {cwd: sandbox.cwd}
    );
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--baseline');
  });

  test('missing required flag exits 1', () => {
    const exit = run(['--baseline', sandbox.baselineDir, '--json'], {
      cwd: sandbox.cwd,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('required');
  });

  test('non-json output prints tabular summary', () => {
    sandbox.writeTree('cwd', 'app/foo.ts', 'X\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'X\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'Y\n');
    sandbox.writeManifest({'app/foo.ts': 'owned'});

    const exit = run(
      [
        '--baseline',
        sandbox.baselineDir,
        '--latest',
        sandbox.latestDir,
        '--manifest',
        sandbox.manifestPath,
      ],
      {cwd: sandbox.cwd}
    );
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    expect(out).toContain('gaia update merge');
    expect(out).toContain('Overwrite: 1');
  });

  test('emitted patch is `git apply --check` clean for owned conflict', () => {
    // Create a real git repo at the sandbox cwd so `git apply --check`
    // has somewhere to evaluate the patch.
    execFileSync('git', ['init', '-q'], {cwd: sandbox.cwd});
    sandbox.writeTree('cwd', 'app/foo.ts', 'adopter line\n');
    sandbox.writeTree('baseline', 'app/foo.ts', 'pristine\n');
    sandbox.writeTree('latest', 'app/foo.ts', 'upstream line\n');
    sandbox.writeManifest({'app/foo.ts': 'owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.conflicts).toHaveLength(1);
    const patchAbs = path.join(sandbox.cwd, report.conflicts[0]!.patch_path);
    // Apply against the working-tree state ('adopter line\n').
    // git apply --check should report success on the unified diff
    // we generated against the same `from` text.
    expect(() => {
      execFileSync('git', ['apply', '--check', patchAbs], {cwd: sandbox.cwd});
    }).not.toThrow();
  });

  test('wiki-owned class follows shared decision branch', () => {
    const baseline = 'one\ntwo\nthree\n';
    const current = 'one\ntwo\nthree\n';
    const latest = 'one\ntwo\nTHREE\n';
    sandbox.writeTree('cwd', 'wiki/foo.md', current);
    sandbox.writeTree('baseline', 'wiki/foo.md', baseline);
    sandbox.writeTree('latest', 'wiki/foo.md', latest);
    sandbox.writeManifest({'wiki/foo.md': 'wiki-owned'});

    const exit = run(baseArgv(sandbox), {cwd: sandbox.cwd});
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    // Adopter pristine + latest changed → overwrite (any class).
    expect(report.overwrite).toEqual(['wiki/foo.md']);
  });
});
