import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia update regen-regions`.
 *
 * Strategy: hermetic fixture trees under `mkdtempSync`, a synthetic manifest,
 * and a synthetic regeneration program (a small `sh` script the test writes).
 * Never spawns the real `write-audit-remits.sh`; that script's own behavior
 * is covered by its bats suite and by the Phase 4b convergence test.
 *
 * Numbered tests below map to the task doc's "Hostile-input coverage" /
 * "Behavior coverage" obligation list (1-22).
 */
import {execFileSync} from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './regen-regions.js';
import type {RegenRegionsReport} from './regen-regions.js';

const START_MARKER = '<!-- gaia:test:start -->';
const END_MARKER = '<!-- gaia:test:end -->';
const DECLARED_PATHS = ['.claude/agents/one.md', '.claude/agents/two.md'];
const REGEN_SCRIPT_REL = '.gaia/scripts/write-regions.sh';
const DEFAULT_FILES: Record<string, unknown> = {[REGEN_SCRIPT_REL]: 'owned'};

const HAPPY_SCRIPT_BODY = [
  String.raw`printf "regenerated one\n" > .claude/agents/one.md`,
  String.raw`printf "regenerated two\n" > .claude/agents/two.md`,
].join('\n');

let cleanupPaths: string[] = [];

const trackPath = (target: string): string => {
  cleanupPaths.push(target);

  return target;
};

const buildRoot = (): string =>
  trackPath(mkdtempSync(path.join(tmpdir(), 'gaia-regen-regions-')));

const buildGitRoot = (): string => {
  const root = buildRoot();

  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});

  return root;
};

const writeDeclaredFiles = (root: string, label: string): void => {
  mkdirSync(path.join(root, '.claude/agents'), {recursive: true});
  writeFileSync(path.join(root, DECLARED_PATHS[0]), `${label} one\n`);
  writeFileSync(path.join(root, DECLARED_PATHS[1]), `${label} two\n`);
};

const writeScript = (
  root: string,
  body: string,
  scriptRepoPath: string = REGEN_SCRIPT_REL
): void => {
  const abs = path.join(root, scriptRepoPath);

  mkdirSync(path.dirname(abs), {recursive: true});
  writeFileSync(abs, `#!/bin/sh\nset -e\n${body}\n`);
  chmodSync(abs, 0o755);
};

const writeManifest = (
  root: string,
  regions: unknown[],
  files: Record<string, unknown> = DEFAULT_FILES
): string => {
  const manifestPath = path.join(root, 'manifest.json');

  writeFileSync(
    manifestPath,
    JSON.stringify({
      files,
      generated: '2024-01-01T00:00:00.000Z',
      regions,
      version: '1.0.0',
    })
  );

  return manifestPath;
};

type RegenerateOverrides = Partial<{
  args: string[];
  interpreter: string;
  operand: string;
}>;

const buildDeclaration = (
  overrides: {
    id?: string;
    paths?: string[];
    regenerate?: RegenerateOverrides;
  } = {}
): Record<string, unknown> => ({
  endMarker: END_MARKER,
  id: overrides.id ?? 'test-region',
  paths: overrides.paths ?? [...DECLARED_PATHS],
  regenerate: {
    args: [],
    interpreter: 'sh',
    operand: REGEN_SCRIPT_REL,
    ...overrides.regenerate,
  },
  startMarker: START_MARKER,
});

const baseArgv = (
  manifestPath: string,
  root: string,
  extra: string[] = []
): string[] => ['--manifest', manifestPath, '--root', root, '--json', ...extra];

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

const runCapturing = (
  argv: string[]
): {exit: number; report: RegenRegionsReport; stderrText: string} => {
  const stdio = captureStdio();
  const exit = run(argv);

  stdio.restore();

  return {
    exit,
    report: JSON.parse(stdio.outputs.join('').trim()) as RegenRegionsReport,
    stderrText: stdio.errors.join(''),
  };
};

/** For the flags/manifest fatal-error paths: no report is ever printed. */
const runFailing = (argv: string[]): {exit: number; stderrText: string} => {
  const stdio = captureStdio();
  const exit = run(argv);

  stdio.restore();

  return {exit, stderrText: stdio.errors.join('')};
};

const readDeclared = (root: string, index: 0 | 1): string =>
  readFileSync(path.join(root, DECLARED_PATHS[index]), 'utf8');

const byLocale = (a: string, b: string): number => a.localeCompare(b);
// Bound to a variable before sorting: canonical/no-use-extend-native's
// proto-method database predates ES2023 and does not recognize `toSorted`
// on an inline array-spread expression.
const declaredPathsCopy = [...DECLARED_PATHS];
const SORTED_DECLARED_PATHS = declaredPathsCopy.toSorted(byLocale);

beforeEach(() => {
  cleanupPaths = [];
});

afterEach(() => {
  cleanupPaths.forEach((target) => {
    rmSync(target, {force: true, recursive: true});
  });
  vi.restoreAllMocks();
});

describe('update regen-regions: hostile-input coverage', () => {
  test('1. absolute operand is refused; nothing spawned', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const absoluteOperand = path.join(root, REGEN_SCRIPT_REL);
    const manifestPath = writeManifest(
      root,
      [buildDeclaration({regenerate: {operand: absoluteOperand}})],
      {[absoluteOperand]: 'owned'}
    );

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toHaveLength(1);
    expect(report.refused[0]?.kind).toBe('operand');
    expect(report.refused[0]?.reason).toBe('operand is an absolute path');
    expect(report.refused[0]?.argv).toBeDefined();
    expect(readDeclared(root, 0)).toBe('original one\n');
  });

  test('1a. declared path escaping the root with a parent-directory segment is refused; nothing spawned', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // Every consumer of a declared path resolves it against --root: the
    // backup copies it, the snapshot walks its parent directory, and the
    // sweep writes and deletes inside that directory. An unguarded entry
    // reaches outside --root on all three.
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: ['../../victim/file.md']}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.refused).toHaveLength(1);
    expect(report.refused[0]?.kind).toBe('declaration');
    expect(report.refused[0]?.reason).toBe(
      'paths carries a parent-directory segment: ../../victim/file.md'
    );
  });

  test('1b. absolute declared path is refused', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: [path.join(root, DECLARED_PATHS[0])]}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.refused[0]?.kind).toBe('declaration');
    expect(report.refused[0]?.reason).toMatch(
      /^paths carries an absolute path/u
    );
  });

  test('1c. empty declared path is refused', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration({paths: ['']})]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.refused[0]?.reason).toBe('paths carries an empty entry');
  });

  test('1e. a declared path whose parent is the repository root is refused, so the snapshot never scopes to the whole tree', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // A literal '.' passes the empty, absolute, and parent-segment checks,
    // and so does any legitimate top-level path. Both scope the snapshot to
    // the root. '.' additionally never equals a snapshot key, so the sweep
    // reverts the region's own output while reporting the region as run.
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: ['.']}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.confined).toHaveLength(0);
    expect(report.refused[0]?.kind).toBe('declaration');
    expect(report.refused[0]?.reason).toBe(
      'paths carries a path whose parent is the repository root: .'
    );
  });

  test('1f. a top-level declared path is refused for the same reason', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: ['CHANGELOG.md']}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.refused[0]?.reason).toBe(
      'paths carries a path whose parent is the repository root: CHANGELOG.md'
    );
  });

  test('1d. a declared path written as ./a/b still matches its own snapshot key, so the run is not reverted', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // The snapshot canonicalizes its keys through path.relative, so an
    // un-normalized declared path would miss its own entry and the sweep
    // would revert the file the regeneration just wrote, while still
    // reporting the region as successfully run.
    const manifestPath = writeManifest(root, [
      buildDeclaration({
        paths: DECLARED_PATHS.map((declPath) => `./${declPath}`),
      }),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toHaveLength(0);
    expect(report.ran).toHaveLength(1);
    expect(report.confined).toHaveLength(0);
    expect(readDeclared(root, 0)).not.toBe('original one\n');
  });

  test('2. operand carrying a parent-directory segment is refused, even though it resolves to a shipped file', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // Resolves on disk to the exact same real script as REGEN_SCRIPT_REL, and
    // the files map is seeded with this literal (un-collapsed) string as a
    // key, so a broken '..' check would let this region run to completion.
    const operand = '.gaia/scripts/../scripts/write-regions.sh';
    const manifestPath = writeManifest(
      root,
      [buildDeclaration({regenerate: {operand}})],
      {[operand]: 'owned'}
    );

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused[0]?.reason).toBe(
      'operand carries a parent-directory segment'
    );
    expect(report.ran).toHaveLength(0);
    expect(readDeclared(root, 0)).toBe('original one\n');
  });

  test('3. operand resolving through a symlink outside the repository is refused', () => {
    const root = buildRoot();
    const outsideDir = trackPath(
      mkdtempSync(path.join(tmpdir(), 'gaia-regen-outside-'))
    );
    const outsideScript = path.join(outsideDir, 'evil.sh');

    writeFileSync(
      outsideScript,
      '#!/bin/sh\nprintf "should not run\\n" > /dev/null\n'
    );
    chmodSync(outsideScript, 0o755);

    const linkRepoPath = '.gaia/scripts/escape.sh';
    const linkAbs = path.join(root, linkRepoPath);

    mkdirSync(path.dirname(linkAbs), {recursive: true});
    symlinkSync(outsideScript, linkAbs);
    writeDeclaredFiles(root, 'original');
    const manifestPath = writeManifest(
      root,
      [buildDeclaration({regenerate: {operand: linkRepoPath}})],
      {[linkRepoPath]: 'owned'}
    );

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused[0]?.reason).toBe(
      'operand resolves through a symlink out of the repository'
    );
    expect(readDeclared(root, 0)).toBe('original one\n');
  });

  test('4. operand that is a substring of a shipped key is refused, not matched', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({regenerate: {operand: 'scripts/write-regions.sh'}}),
    ]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.refused[0]?.reason).toBe(
      'operand is not a path this manifest ships'
    );
  });

  test('5. operand that is a suffix of a shipped key is refused', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({regenerate: {operand: 'write-regions.sh'}}),
    ]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.refused[0]?.reason).toBe(
      'operand is not a path this manifest ships'
    );
  });

  test('6. a shipped key with a "./" prefix is accepted after normalization', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({regenerate: {operand: `./${REGEN_SCRIPT_REL}`}}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toEqual([]);
    expect(report.ran).toHaveLength(1);
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
  });

  test('7. a shipped operand whose file does not exist is not refused; the interpreter itself reports the failure via a non-zero exit', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    // REGEN_SCRIPT_REL is a shipped key but no file is ever written there.
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toEqual([]);
    expect(report.failed).toHaveLength(1);
    // `sh` itself is found and runs; it is `sh` that reports "No such file
    // or directory" and exits non-zero, which the frozen classification rule
    // (a defined numeric `status`) correctly reads as 'exit', not 'spawn':
    // Node's execFileSync only reports 'spawn' (ENOENT/EACCES, no `status`)
    // when the INTERPRETER itself cannot be launched (see test 8). Verified
    // empirically; see this task's Notes for orchestrator.
    expect(report.failed[0]?.kind).toBe('exit');
    expect(typeof report.failed[0]?.status).toBe('number');
  });

  test('8. interpreter pointed at a nonexistent program is a spawn failure', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({
        regenerate: {interpreter: 'this-interpreter-does-not-exist-xyz'},
      }),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toEqual([]);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]?.kind).toBe('spawn');
    expect(report.failed[0]?.status).toBeUndefined();
  });

  test('9. the regeneration program exiting non-zero is reported distinctly from a spawn failure', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      [String.raw`printf "partial\n" > .claude/agents/one.md`, 'exit 3'].join(
        '\n'
      )
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]?.kind).toBe('exit');
    expect(report.failed[0]?.status).toBe(3);
    expect(report.ran).toEqual([]);
  });

  test('10. an interpreter containing a path separator is refused', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      buildDeclaration({regenerate: {interpreter: 'bin/sh'}}),
    ]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.refused[0]?.reason).toBe(
      'interpreter is not a bare program name'
    );
  });
});

describe('update regen-regions: behavior coverage', () => {
  test('11. happy path: the program rewrites both declared paths', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.failed).toEqual([]);
    expect(report.refused).toEqual([]);
    expect(report.confined).toEqual([]);
    expect(report.ran).toHaveLength(1);
    const rewrote = report.ran[0]?.rewrote ?? [];

    expect(rewrote.toSorted(byLocale)).toEqual(SORTED_DECLARED_PATHS);
  });

  test('12. a write outside the declared set but inside the snapshot scope is restored', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, '.claude/agents'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/agents/extra.md'),
      'extra original\n'
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        String.raw`printf "clobbered\n" > .claude/agents/extra.md`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/extra.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      readFileSync(path.join(root, '.claude/agents/extra.md'), 'utf8')
    ).toBe('extra original\n');
  });

  test('13. a file created outside the declared set but inside the snapshot scope is removed', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        String.raw`printf "new\n" > .claude/agents/new.md`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.confined).toEqual([
      {
        action: 'removed',
        path: '.claude/agents/new.md',
        regionId: 'test-region',
      },
    ]);
    expect(existsSync(path.join(root, '.claude/agents/new.md'))).toBe(false);
  });

  test('13a. a write entirely outside the snapshot scope is reported, not reverted', () => {
    const root = buildGitRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'mkdir -p app',
        String.raw`printf "out of scope\n" > app/out-of-scope.txt`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    // `git status --porcelain` reports a wholly-new untracked directory as
    // one entry (`app/`), not its individual files; the confined entry
    // carries that literal path.
    expect(report.confined).toEqual([
      {action: 'reported', path: 'app/', regionId: 'test-region'},
    ]);
    expect(readFileSync(path.join(root, 'app/out-of-scope.txt'), 'utf8')).toBe(
      'out of scope\n'
    );
  });

  test('13b. with git unavailable, the snapshot-scoped sweep still runs and the run still exits 0', () => {
    // Deliberately NOT a git repository (plain buildRoot()): the whole-root
    // detector degrades, but nothing about the run fails.
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, '.claude/agents'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/agents/extra.md'),
      'extra original\n'
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        String.raw`printf "clobbered\n" > .claude/agents/extra.md`,
        'mkdir -p app',
        String.raw`printf "out of scope\n" > app/out-of-scope.txt`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root)
    );

    expect(exit).toBe(0);
    // In-scope sweep still ran and reverted the clobbered in-scope file.
    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/extra.md',
        regionId: 'test-region',
      },
    ]);
    // The out-of-scope write was never detected (no git), so it is neither
    // reported nor reverted.
    expect(existsSync(path.join(root, 'app/out-of-scope.txt'))).toBe(true);
    expect(stderrText).toContain('region_regen_git_delta_unavailable');
  });

  test('14. --backup-dir copies a declared path not yet backed up', () => {
    const root = buildRoot();
    const backupDir = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    expect(report.backedUp.toSorted(byLocale)).toEqual(SORTED_DECLARED_PATHS);
    expect(readFileSync(path.join(backupDir, DECLARED_PATHS[0]), 'utf8')).toBe(
      'original one\n'
    );
  });

  test('14a. a failing backup still prints a report and still regenerates', () => {
    const root = buildRoot();
    const backupDir = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // The backup destination's parent exists as a FILE, so mkdirSync throws
    // ENOTDIR. An unguarded throw prints no report at all, and the skill
    // reads empty output as a CLI predating this subcommand rather than as a
    // backup failure, discarding every confinement record with it.
    writeFileSync(path.join(backupDir, '.claude'), 'not a directory\n');
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    expect(exit).toBe(0);
    expect(report.backedUp).toEqual([]);
    expect(report.ran).toHaveLength(1);
    expect(stderrText).toContain('region_regen_backup_failed');
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
  });

  test('15. --backup-dir does not overwrite an existing backup', () => {
    const root = buildRoot();
    const backupDir = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    mkdirSync(path.join(backupDir, '.claude/agents'), {recursive: true});
    writeFileSync(
      path.join(backupDir, DECLARED_PATHS[0]),
      'pre-existing backup\n'
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    expect(report.backedUp).toEqual([DECLARED_PATHS[1]]);
    expect(readFileSync(path.join(backupDir, DECLARED_PATHS[0]), 'utf8')).toBe(
      'pre-existing backup\n'
    );
  });

  test('16. --conflicted naming a declared path skips the whole region', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--conflicted', DECLARED_PATHS[0]])
    );

    expect(report.skipped).toHaveLength(1);
    expect(report.ran).toEqual([]);
    expect(readDeclared(root, 0)).toBe('original one\n');
  });

  test('17. --skip-region names the id', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--skip-region', 'test-region'])
    );

    expect(report.skipped).toEqual([
      {
        argv: ['sh', REGEN_SCRIPT_REL],
        reason: 'inputs not reconciled by this run',
        regionId: 'test-region',
      },
    ]);
  });

  test('17a. --absent-path naming a declared path skips the region without recreating the file', () => {
    const root = buildRoot();

    // Only one of the two declared paths exists; the other was deliberately
    // deleted by the adopter and the skill classified it as absent.
    mkdirSync(path.join(root, '.claude/agents'), {recursive: true});
    writeFileSync(path.join(root, DECLARED_PATHS[0]), 'original one\n');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--absent-path', DECLARED_PATHS[1]])
    );

    expect(report.skipped).toHaveLength(1);
    expect(existsSync(path.join(root, DECLARED_PATHS[1]))).toBe(false);
  });

  test('17b. argv is present on skipped[], and absent on a declaration refusal (test 1 already covers an operand refusal carrying argv)', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      {}, // no id at all: falls back to a region-at-index-N id
      buildDeclaration({
        id: 'skip-me',
        regenerate: {operand: '.gaia/scripts/write-regions.sh'},
      }),
    ]);

    const {report} = runCapturing(
      baseArgv(manifestPath, root, ['--skip-region', 'skip-me'])
    );

    const declarationRefusal = report.refused.find(
      (entry) => entry.regionId === 'region-at-index-0'
    );

    expect(declarationRefusal?.kind).toBe('declaration');
    expect(declarationRefusal).not.toHaveProperty('argv');
    expect(report.skipped[0]?.argv).toEqual(['sh', REGEN_SCRIPT_REL]);
  });

  test('18. manifest with no regions key produces an empty report', () => {
    const root = buildRoot();
    const manifestPath = path.join(root, 'manifest.json');

    writeFileSync(
      manifestPath,
      JSON.stringify({
        files: {},
        generated: '2024-01-01T00:00:00.000Z',
        version: '1.0.0',
      })
    );

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report).toEqual({
      backedUp: [],
      confined: [],
      failed: [],
      ran: [],
      refused: [],
      skipped: [],
    });
  });

  test('19. manifest with regions: [] produces the same empty report', () => {
    const root = buildRoot();
    const manifestPath = writeManifest(root, []);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toEqual([]);
    expect(report.refused).toEqual([]);
  });

  test('20. malformed declarations are refused by name; other declarations still process; exit 0', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [
      'not-an-object',
      {
        endMarker: END_MARKER,
        id: '  ',
        paths: [],
        regenerate: {},
        startMarker: START_MARKER,
      },
      {
        endMarker: END_MARKER,
        id: 'dup',
        paths: [],
        regenerate: {},
        startMarker: '',
      },
      {
        endMarker: END_MARKER,
        id: 'dup',
        paths: [],
        regenerate: {args: [], interpreter: 'sh', operand: REGEN_SCRIPT_REL},
        startMarker: START_MARKER,
      },
      buildDeclaration({id: 'healthy'}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused.map((entry) => entry.reason)).toEqual([
      'declaration is not an object',
      'declaration is missing a non-empty id',
      'startMarker is missing or empty',
      'duplicate region id: dup',
    ]);
    expect(report.ran).toHaveLength(1);
    expect(report.ran[0]?.regionId).toBe('healthy');
  });
});

describe('update regen-regions: exit codes', () => {
  test('21a. a missing required flag exits 1 with invalid_arguments', () => {
    const root = buildRoot();
    const manifestPath = writeManifest(root, []);

    const {exit, stderrText} = runFailing([
      '--manifest',
      manifestPath,
      '--json',
    ]);

    expect(exit).toBe(1);
    expect(stderrText).toContain('invalid_arguments');
  });

  test('21b. a manifest that does not exist exits 1 with manifest_not_found', () => {
    const root = buildRoot();

    const {exit, stderrText} = runFailing(
      baseArgv(path.join(root, 'missing-manifest.json'), root)
    );

    expect(exit).toBe(1);
    expect(stderrText).toContain('manifest_not_found');
  });

  test('21c. a manifest that is not valid JSON exits 1 with manifest_parse_failed', () => {
    const root = buildRoot();
    const manifestPath = path.join(root, 'manifest.json');

    writeFileSync(manifestPath, '{not json');

    const {exit, stderrText} = runFailing(baseArgv(manifestPath, root));

    expect(exit).toBe(1);
    expect(stderrText).toContain('manifest_parse_failed');
  });

  test('21d. a run mixing refused, skipped, and failed regions still exits 0', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, ['exit 9'].join('\n'));
    const manifestPath = writeManifest(root, [
      {id: 'broken'},
      buildDeclaration({id: 'skip-me'}),
      buildDeclaration({
        id: 'fail-me',
        paths: ['.claude/agents/two.md'],
      }),
    ]);

    const {exit, report} = runCapturing(
      baseArgv(manifestPath, root, ['--skip-region', 'skip-me'])
    );

    expect(exit).toBe(0);
    expect(report.refused).toHaveLength(1);
    expect(report.skipped).toHaveLength(1);
    expect(report.failed).toHaveLength(1);
  });

  test('22. idempotence: a second run against a converged tree rewrites nothing', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const first = runCapturing(baseArgv(manifestPath, root));

    expect(first.report.ran[0]?.rewrote).toHaveLength(2);

    const beforeSecondRun = {
      one: readDeclared(root, 0),
      two: readDeclared(root, 1),
    };
    const second = runCapturing(baseArgv(manifestPath, root));

    expect(second.report.ran[0]?.rewrote).toEqual([]);
    expect(readDeclared(root, 0)).toBe(beforeSecondRun.one);
    expect(readDeclared(root, 1)).toBe(beforeSecondRun.two);
  });
});
