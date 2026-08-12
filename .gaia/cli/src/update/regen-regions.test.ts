/**
 * Strategy: hermetic fixture trees under `mkdtempSync`, a synthetic manifest,
 * and a synthetic regeneration program (a small `sh` script the test writes).
 * Never spawns the real `write-audit-remits.sh`; that script's own behavior
 * is covered by its bats suite.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import type * as nodeFs from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveTimeoutMs, run, spawnFailureCause} from './regen-regions.js';
import type {RegenRegionsReport} from './regen-regions.js';

/**
 * `vi.mock` is hoisted above every import, so the switch its factory closes
 * over has to be built by `vi.hoisted` rather than declared as an ordinary
 * module-level const.
 *
 * The factory delegates every call to the real `node:fs`, including
 * `readlinkSync` itself, until a test arms the one-shot below. It exists for a
 * single entry: no filesystem state makes a real `readlink` fail while the
 * `lstat` immediately before it succeeds (both need the same search permission
 * on the same parent), so the transient window the snapshot's symlink arm has
 * to survive is reachable only this way.
 */
const fsControl = vi.hoisted(() => ({failReadlinkOnceFor: '', failRmFor: ''}));

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof nodeFs>();
  const realReadlink = actual.readlinkSync as (
    target: unknown,
    options?: unknown
  ) => unknown;
  const realRm = actual.rmSync as (target: unknown, options?: unknown) => void;

  return {
    ...actual,
    readlinkSync: (target: unknown, options?: unknown): unknown => {
      if (
        fsControl.failReadlinkOnceFor !== '' &&
        String(target).endsWith(fsControl.failReadlinkOnceFor)
      ) {
        fsControl.failReadlinkOnceFor = '';

        const error: NodeJS.ErrnoException = new Error(
          'EIO: i/o error, readlink'
        );

        error.code = 'EIO';

        throw error;
      }

      return realReadlink(target, options);
    },
    rmSync: (target: unknown, options?: unknown): void => {
      if (
        fsControl.failRmFor !== '' &&
        String(target).endsWith(fsControl.failRmFor)
      ) {
        const error: NodeJS.ErrnoException = new Error(
          'EACCES: permission denied, unlink'
        );

        error.code = 'EACCES';

        throw error;
      }

      realRm(target, options);
    },
  };
});

const START_MARKER = '<!-- gaia:test:start -->';
const END_MARKER = '<!-- gaia:test:end -->';
const DECLARED_PATHS = [
  '.claude/agents/one.md',
  '.claude/agents/two.md',
] as const;
const REGEN_SCRIPT_REL = '.gaia/scripts/write-regions.sh';
const DEFAULT_FILES: Record<string, unknown> = {[REGEN_SCRIPT_REL]: 'owned'};

/** Shell fragment writing 2 MiB to stdout, twice execFileSync's 1 MiB default. */
const TWO_MIB = `awk 'BEGIN { while (i++ < 2048) printf "%1024s", "" }'`;

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

/** Writes a file and commits it, so `git status` can report on it later. */
const commitFixture = (root: string, relPath: string, body: string): void => {
  const abs = path.join(root, relPath);

  mkdirSync(path.dirname(abs), {recursive: true});
  writeFileSync(abs, body);
  execFileSync('git', ['add', '--', relPath], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'fixture'], {cwd: root});
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

// `regions` is `unknown`, not `unknown[]`: the wrong-typed-key tests need to
// write a manifest whose `regions` is not an array at all.
const writeManifest = (
  root: string,
  regions: unknown,
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
  argv: string[],
  options: Parameters<typeof run>[1] = {}
): {exit: number; report: RegenRegionsReport; stderrText: string} => {
  const stdio = captureStdio();
  const exit = run(argv, options);

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

/**
 * Runs one nested-scope-dir declaration order and returns what the sweep did
 * to the node BOTH scopes key, so two orders can be compared directly.
 */
const runNestedScopeOrder = (
  paths: string[]
): {confined: RegenRegionsReport['confined']; content: string} => {
  const root = buildRoot();

  writeDeclaredFiles(root, 'original');
  // `.claude/agents/sub` is an undeclared regular file the program
  // clobbers, and it is ALSO the parent of a declared path, so the outer
  // scope's walk keys it as an entry while the inner scope's gate keys it
  // as its own root.
  writeFileSync(path.join(root, '.claude/agents/sub'), 'adopter bytes\n');
  writeScript(
    root,
    [
      HAPPY_SCRIPT_BODY,
      String.raw`printf "spawn bytes\n" > .claude/agents/sub`,
    ].join('\n')
  );
  const manifestPath = writeManifest(root, [buildDeclaration({paths})]);
  const {report} = runCapturing(baseArgv(manifestPath, root));

  return {
    confined: report.confined.toSorted((a, b) => a.path.localeCompare(b.path)),
    content: readFileSync(path.join(root, '.claude/agents/sub'), 'utf8'),
  };
};

const byLocale = (a: string, b: string): number => a.localeCompare(b);
// Bound to a variable before sorting: canonical/no-use-extend-native's
// proto-method database predates ES2023 and does not recognize `toSorted`
// on an inline array-spread expression.
const declaredPathsCopy = [...DECLARED_PATHS];
const SORTED_DECLARED_PATHS = declaredPathsCopy.toSorted(byLocale);

beforeEach(() => {
  cleanupPaths = [];
  fsControl.failReadlinkOnceFor = '';
  fsControl.failRmFor = '';
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

  // Every one of these names the root rather than a path under it, and is
  // nothing but `.` segments, so normalization takes each to the empty string
  // and the empty-entry guard refuses it. Scoping the snapshot to the whole
  // tree is the outcome being refused; a legitimate top-level path reaches it
  // too, by the parent-is-the-root guard instead (test 1f), and a bare `/`
  // reaches it by the absolute-path guard (test 1j).
  test.each(['.', './', '././'])(
    '1e. a declared path naming the repository root itself (%p) is refused, so the snapshot never scopes to the whole tree',
    (declPath) => {
      const root = buildRoot();

      writeDeclaredFiles(root, 'original');
      writeScript(root, HAPPY_SCRIPT_BODY);
      const manifestPath = writeManifest(root, [
        buildDeclaration({paths: [declPath]}),
      ]);

      const {exit, report} = runCapturing(baseArgv(manifestPath, root));

      expect(exit).toBe(0);
      expect(report.ran).toHaveLength(0);
      expect(report.confined).toHaveLength(0);
      expect(report.refused[0]?.kind).toBe('declaration');
      expect(report.refused[0]?.reason).toBe('paths carries an empty entry');
    }
  );

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

  test('1g. a declared path written with a trailing slash still matches its own snapshot key', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // 1d's shape one separator over. A trailing slash reaches `declaredSet`
    // verbatim unless normalization strips it, and no snapshot key can carry
    // one, so the sweep reads the region's own output as an undeclared write
    // and reverts it while `ran` still reports the region as run.
    const manifestPath = writeManifest(root, [
      buildDeclaration({
        paths: DECLARED_PATHS.map((declPath) => `${declPath}/`),
      }),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toHaveLength(0);
    expect(report.ran).toHaveLength(1);
    expect(report.confined).toHaveLength(0);
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
  });

  test('1h. a declared path carrying an interior "/./" still matches its own snapshot key', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // The third shape of 1d's defect, and the one that reached a second
    // consumer: `scopeDirsFor` takes the declared path's `dirname`, so an
    // interior '.' segment also lands in the scope-dir set in a form no
    // snapshot key can equal.
    const manifestPath = writeManifest(root, [
      buildDeclaration({
        paths: DECLARED_PATHS.map((declPath) =>
          declPath.replace('/agents/', '/agents/./')
        ),
      }),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.refused).toHaveLength(0);
    expect(report.ran).toHaveLength(1);
    expect(report.confined).toHaveLength(0);
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
  });

  test.each(['/', '//'])(
    '1j. a bare separator (%p) is refused as the absolute path it is, not as an empty entry',
    (declPath) => {
      const root = buildRoot();

      writeDeclaredFiles(root, 'original');
      writeScript(root, HAPPY_SCRIPT_BODY);
      // Normalization strips a trailing separator, but never the last one: a
      // lone '/' reduced to the empty string would be refused for the least
      // descriptive of the four reasons, naming neither what was written nor
      // why it cannot be declared. `/.` is deliberately not here: it carries a
      // `.` segment and nothing else, so it normalizes away exactly as `.`
      // does and 1e's empty-entry refusal is the one it earns.
      const manifestPath = writeManifest(root, [
        buildDeclaration({paths: [declPath]}),
      ]);

      const {exit, report} = runCapturing(baseArgv(manifestPath, root));

      expect(exit).toBe(0);
      expect(report.ran).toHaveLength(0);
      expect(report.refused[0]?.reason).toBe(
        'paths carries an absolute path: /'
      );
    }
  );

  test('1i. a declared path that normalizes onto the repository root is refused, not silently un-matchable', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // '.claude/.' names the directory `.claude`, whose parent is the root.
    // Before normalization reached interior '.' segments this passed every
    // guard and then matched no snapshot key, which is 1e's failure mode
    // arriving by a shape 1e does not cover.
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: ['.claude/.']}),
    ]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.ran).toHaveLength(0);
    expect(report.confined).toHaveLength(0);
    expect(report.refused[0]?.reason).toBe(
      'paths carries a path whose parent is the repository root: .claude'
    );
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

  test('9a. a regeneration program killed by a signal is reported distinctly from an interpreter that never launched', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    // The shell signals itself: `status` is null on the thrown error, exactly
    // as it is when the interpreter could not be launched at all. Only the
    // signal tells the two apart.
    writeScript(root, 'kill -TERM $$');
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]?.kind).toBe('killed');
    expect(report.failed[0]?.signal).toBe('SIGTERM');
    // Neither of this command's own bounds ended it, and saying so is what
    // keeps an operator's own kill from reading as GAIA imposing a ceiling.
    expect(report.failed[0]?.cause).toBe('external');
    expect(report.ran).toEqual([]);
  });

  test('9c. a regeneration program stopped by the output bound names that bound, not a bare signal', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    // 33 MiB down stderr, past the command's own 32 MiB ceiling. stdout is
    // discarded outright, so stderr is the only stream that can reach it.
    writeScript(
      root,
      'awk \'BEGIN { while (i++ < 33792) printf "%1024s", "" }\' >&2'
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]?.kind).toBe('killed');
    expect(report.failed[0]?.signal).toBe('SIGTERM');
    expect(report.failed[0]?.cause).toBe('maxBuffer');
  });

  test('9e. a regeneration program stopped by the time bound names that bound, not a bare signal', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    // Sleeps 20x the bound this run is given, which is margin enough on a
    // loaded machine and short enough that a regression costs seconds rather
    // than the shipped five minutes: nothing can interrupt the synchronous
    // spawn, so a broken injection point waits out the whole sleep. 9c's twin
    // on the other arm, both proving a real kill reaches the cause mapping
    // rather than only the mapping's string handling (9d).
    writeScript(root, 'sleep 5');
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root), {
      spawnTimeoutMs: 250,
    });

    expect(exit).toBe(0);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]?.kind).toBe('killed');
    expect(report.failed[0]?.signal).toBe('SIGTERM');
    expect(report.failed[0]?.cause).toBe('timeout');
  });

  test('9f. the time-bound override only ever lowers the bound, and a non-positive one is ignored', () => {
    // Asserted on the resolver rather than through a run, for the same reason
    // 9d asserts on `spawnFailureCause`: end to end, `timeout: 0` and the
    // shipped five minutes are indistinguishable inside a suite, since both
    // let a fast script finish. Only the resolver can be asked directly, and
    // an assertion that cannot fail for the reason it exists is worth nothing.
    const shipped = resolveTimeoutMs(undefined);

    // Node reads `timeout: 0` as NO timeout, so the one value that would
    // remove the guard must not be honoured by the option that lowers it.
    expect(resolveTimeoutMs(0)).toBe(shipped);
    expect(resolveTimeoutMs(-1)).toBe(shipped);
    expect(resolveTimeoutMs(Number.NaN)).toBe(shipped);
    // Lowering is the whole of what it is for; raising is refused.
    expect(resolveTimeoutMs(250)).toBe(250);
    expect(resolveTimeoutMs(shipped + 1)).toBe(shipped);
  });

  test('9d. every kill cause maps from the code Node reports, and an unknown one is external', () => {
    // The mapping itself, apart from the wiring that feeds it: 9c and 9e drive
    // the two bounds end-to-end, and this pins the string handling, including
    // the two shapes no spawn produces.
    expect(spawnFailureCause('ETIMEDOUT')).toBe('timeout');
    expect(spawnFailureCause('ENOBUFS')).toBe('maxBuffer');
    expect(spawnFailureCause('EPIPE')).toBe('external');
    expect(spawnFailureCause(undefined)).toBe('external');
  });

  test('9b. a regeneration program that writes more than Node’s default 1 MiB to stdout and stderr is not killed', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      // 2 MiB down each stream, twice execFileSync's default maxBuffer.
      [TWO_MIB, `${TWO_MIB} >&2`, HAPPY_SCRIPT_BODY].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.failed).toEqual([]);
    expect(report.ran).toHaveLength(1);
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
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

  test('11a. a declared path that is a symlink the program repoints is reported as rewritten', () => {
    const root = buildRoot();
    const linkDeclPath = '.claude/agents/link.md';

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'targets'), {recursive: true});
    writeFileSync(path.join(root, 'targets/a.txt'), 'A\n');
    writeFileSync(path.join(root, 'targets/b.txt'), 'B\n');
    symlinkSync('../../targets/a.txt', path.join(root, linkDeclPath));
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        `rm ${linkDeclPath}`,
        `ln -s ../../targets/b.txt ${linkDeclPath}`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [
      buildDeclaration({paths: [...DECLARED_PATHS, linkDeclPath]}),
    ]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // `rewrote` is what Step 9 renders to tell an adopter which files now
    // intentionally differ from the release copy, so a declared path missing
    // from it is one they are never told about. Comparing content digests
    // alone calls this path unchanged however the program repointed it,
    // because neither side of a link has a digest to differ on.
    expect(report.ran[0]?.rewrote ?? []).toContain(linkDeclPath);
    expect(readlinkSync(path.join(root, linkDeclPath))).toBe(
      '../../targets/b.txt'
    );
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

  test('12a. a file DELETED outside the declared set but inside the snapshot scope is restored', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeFileSync(
      path.join(root, '.claude/agents/extra.md'),
      'extra original\n'
    );
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'rm .claude/agents/extra.md'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
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

  test('12b. a deleted in-scope file whose parent directory the program also removed is still restored', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, '.claude/agents/nested'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/agents/nested/extra.md'),
      'nested original\n'
    );
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'rm -rf .claude/agents/nested'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/nested/extra.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      readFileSync(path.join(root, '.claude/agents/nested/extra.md'), 'utf8')
    ).toBe('nested original\n');
  });

  test('12c. a declared path the program deletes is left deleted: the declared set owns it', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      [
        String.raw`printf "regenerated one\n" > .claude/agents/one.md`,
        `rm ${DECLARED_PATHS[1]}`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.confined).toEqual([]);
    expect(existsSync(path.join(root, DECLARED_PATHS[1]))).toBe(false);
  });

  test('12d. a symlink the program deletes in scope is restored as a symlink, never as a regular file', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    symlinkSync(
      '../../outside/target.txt',
      path.join(root, '.claude/agents/link.md')
    );
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'rm .claude/agents/link.md'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // A deletion outside the declared set is reverted from its pre-image, and
    // a link's pre-image is the target string it held. Putting the LINK back
    // is the faithful revert; writing a regular file carrying the target's
    // bytes would be the mechanism inventing content that lived outside the
    // region, which is the one thing it must never do.
    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/link.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      lstatSync(path.join(root, '.claude/agents/link.md')).isSymbolicLink()
    ).toBe(true);
    expect(readlinkSync(path.join(root, '.claude/agents/link.md'))).toBe(
      '../../outside/target.txt'
    );
    expect(readFileSync(path.join(root, 'outside/target.txt'), 'utf8')).toBe(
      'TARGET CONTENT\n'
    );
  });

  test('12d-i. a symlink the program retargets in scope is put back on its original target', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    writeFileSync(path.join(root, 'outside/other.txt'), 'OTHER CONTENT\n');
    symlinkSync(
      '../../outside/target.txt',
      path.join(root, '.claude/agents/link.md')
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'rm .claude/agents/link.md',
        'ln -s ../../outside/other.txt .claude/agents/link.md',
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Same path, same kind, different target: comparing links by presence
    // alone would call this untouched and leave the region pointing an
    // undeclared path somewhere it chose.
    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/link.md',
        regionId: 'test-region',
      },
    ]);
    expect(readlinkSync(path.join(root, '.claude/agents/link.md'))).toBe(
      '../../outside/target.txt'
    );
  });

  test('12d-ii. a symlink the program replaces with a regular file is put back as a link', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    symlinkSync(
      '../../outside/target.txt',
      path.join(root, '.claude/agents/link.md')
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'rm .claude/agents/link.md',
        String.raw`printf "now a real file\n" > .claude/agents/link.md`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Swapping a link for a regular file is an out-of-scope write like any
    // other, and the link's own pre-image is its target string, so it is put
    // back as a link. Reporting nothing here would let the program's own
    // undeclared content survive at the path under a clean confinement result.
    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/link.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      lstatSync(path.join(root, '.claude/agents/link.md')).isSymbolicLink()
    ).toBe(true);
    expect(readlinkSync(path.join(root, '.claude/agents/link.md'))).toBe(
      '../../outside/target.txt'
    );
    // Restoring a link writes no content, so the target is untouched.
    expect(readFileSync(path.join(root, 'outside/target.txt'), 'utf8')).toBe(
      'TARGET CONTENT\n'
    );
  });

  test('12d-iii. a link whose target is not valid UTF-8 is restored byte-for-byte', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    // A symlink target is an arbitrary byte string on both Linux and macOS.
    // Decoding one as UTF-8 does not throw on an invalid byte, it silently
    // substitutes U+FFFD, so a target read that way and written back points
    // somewhere else entirely while the report claims it was restored, and
    // the true pre-image is gone by then.
    const rawTarget = Buffer.from([
      0x2e, 0x2e, 0x2f, 0xff, 0x2e, 0x74, 0x78, 0x74,
    ]);
    const linkAbs = path.join(root, '.claude/agents/link.md');

    symlinkSync(rawTarget, linkAbs);
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'rm .claude/agents/link.md'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/link.md',
        regionId: 'test-region',
      },
    ]);
    expect(readlinkSync(linkAbs, 'buffer').equals(rawTarget)).toBe(true);
  });

  test('12e. a symlink the program creates in scope is removed, like any other undeclared creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'ln -s ../../outside/target.txt .claude/agents/sneak.md',
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // A link the spawn created is an undeclared creation with no pre-image, so
    // it is removed exactly as a regular file would be; letting it survive
    // would leave the confinement guarantee claiming a clean run while an
    // undeclared path persists. Unlinking never touches what it pointed at.
    expect(report.confined).toEqual([
      {
        action: 'removed',
        path: '.claude/agents/sneak.md',
        regionId: 'test-region',
      },
    ]);
    expect(existsSync(path.join(root, '.claude/agents/sneak.md'))).toBe(false);
    // Removing the link must never touch what it pointed at.
    expect(readFileSync(path.join(root, 'outside/target.txt'), 'utf8')).toBe(
      'TARGET CONTENT\n'
    );
  });

  test('12f. a symlink the program puts where an in-scope file was is restored without writing through the link', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeFileSync(
      path.join(root, '.claude/agents/extra.md'),
      'extra original\n'
    );
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'rm .claude/agents/extra.md',
        'ln -s ../../outside/target.txt .claude/agents/extra.md',
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
    // The pre-image goes back at the path itself, which must be a regular file
    // again. Following the link would write these bytes into the target, which
    // can live anywhere in or outside the tree: the confinement mechanism
    // writing outside the scope it exists to enforce.
    expect(lstatSync(path.join(root, '.claude/agents/extra.md')).isFile()).toBe(
      true
    );
    expect(
      readFileSync(path.join(root, '.claude/agents/extra.md'), 'utf8')
    ).toBe('extra original\n');
    expect(readFileSync(path.join(root, 'outside/target.txt'), 'utf8')).toBe(
      'TARGET CONTENT\n'
    );
  });

  test('12g. an executable the program deletes in scope comes back executable', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    const helperAbs = path.join(root, '.claude/agents/helper.sh');

    writeFileSync(helperAbs, '#!/bin/sh\necho helper\n');
    chmodSync(helperAbs, 0o755);
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'rm .claude/agents/helper.sh'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/helper.sh',
        regionId: 'test-region',
      },
    ]);
    // `restored` has to mean restored. Recreating the content under the
    // process umask hands back a file the adopter can no longer run, while
    // the report claims it was put back.
    expect(statSync(helperAbs).mode.toString(8).slice(-3)).toBe('755');
  });

  test('12h. a scope subdirectory that is a symlink is never descended into, so nothing behind it is snapshotted or written back', () => {
    const root = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeFileSync(path.join(outside, 'precious.txt'), 'PRECIOUS\n');
    symlinkSync(outside, path.join(root, '.claude/agents/linkdir'));
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        String.raw`printf "clobbered\n" > .claude/agents/linkdir/precious.txt`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Nothing behind the link is in either snapshot, so the sweep has nothing
    // to put back there. The spawn's own write stands, and that is the correct
    // outcome rather than a gap: it landed outside the repository, where this
    // command has no pre-image and no business writing. Reverting it would be
    // the confinement mechanism writing outside the very tree it exists to
    // confine writes to, at a path `report.confined` names repo-relatively
    // while the bytes land somewhere else entirely.
    expect(report.confined).toEqual([]);
    expect(readFileSync(path.join(outside, 'precious.txt'), 'utf8')).toBe(
      'clobbered\n'
    );
    // The link itself is still snapshotted as itself, so the guarantee still
    // covers every shape the link can be left in.
    expect(readlinkSync(path.join(root, '.claude/agents/linkdir'))).toBe(
      outside
    );
  });

  test('12h-i. a scope subdirectory the program replaces with a symlink is not a write path out of the repository', () => {
    const root = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, '.claude/agents/nested'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/agents/nested/extra.md'),
      'nested original\n'
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'rm -rf .claude/agents/nested',
        `ln -s "${outside}" .claude/agents/nested`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Every snapshot key is lexical, and the tree they go back into is the one
    // the spawn just finished editing. Restoring the deleted file while the
    // spawn's link still occupies its parent resolves the write inside
    // `outside`: the pre-image leaves the repository, the report calls it
    // `restored` at a repo-relative path, and the path itself stays empty.
    // Undoing the spawn's creations first is what keeps the write lexical.
    expect(existsSync(path.join(outside, 'extra.md'))).toBe(false);

    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'removed',
        path: '.claude/agents/nested',
        regionId: 'test-region',
      },
      {
        action: 'restored',
        path: '.claude/agents/nested/extra.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      readFileSync(path.join(root, '.claude/agents/nested/extra.md'), 'utf8')
    ).toBe('nested original\n');
    expect(
      lstatSync(path.join(root, '.claude/agents/nested')).isDirectory()
    ).toBe(true);
  });

  test('12h-ii. when that symlink cannot be removed, the restore refuses rather than resolving through it', () => {
    const root = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, '.claude/agents/nested'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/agents/nested/extra.md'),
      'nested original\n'
    );
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'rm -rf .claude/agents/nested',
        `ln -s "${outside}" .claude/agents/nested`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    // The removal that would clear the spawn's link fails, which is ordinary:
    // unlinking it needs write permission on the scope directory, while writing
    // through it needs nothing but a writable target somewhere else.
    fsControl.failRmFor = '.claude/agents/nested';

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Both entries are surfaced and neither is written. A `restored` row here
    // would be the worst available outcome: the bytes outside the tree, the
    // path inside it still empty, and the report claiming the opposite.
    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/nested',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/nested/extra.md',
        regionId: 'test-region',
      },
    ]);
    expect(existsSync(path.join(outside, 'extra.md'))).toBe(false);
  });

  test('12h-iii. a scope directory reached through a symlinked ancestor is not snapshotted, so nothing behind it is written into the repository', () => {
    const root = buildRoot();
    const outside = buildRoot();

    // The adopter keeps `.claude` outside the repository and links to it, which
    // is self-consistent for as long as the link is there: both snapshot passes
    // and every write resolve through it and land where they were read.
    mkdirSync(path.join(outside, 'agents'), {recursive: true});
    writeFileSync(path.join(outside, 'agents/one.md'), 'original one\n');
    writeFileSync(path.join(outside, 'agents/two.md'), 'original two\n');
    writeFileSync(path.join(outside, 'agents/private.env'), 'SECRET=1\n');
    symlinkSync(outside, path.join(root, '.claude'));
    // Replacing that link with a real directory is what ends the consistency:
    // the pre-images were read THROUGH the link, and the restore afterwards
    // resolves the same keys lexically, into the repository.
    writeScript(
      root,
      ['rm .claude', 'mkdir -p .claude/agents', HAPPY_SCRIPT_BODY].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // `lstat` on the scope directory resolves every component above it, so a
    // walk that only refuses a link at the last position descends straight
    // through this one and keys out-of-tree files as though they lived here.
    // Putting one back then materializes the adopter's private file INSIDE the
    // repository, at a path that has never held it.
    expect(existsSync(path.join(root, '.claude/agents/private.env'))).toBe(
      false
    );
    // Nothing behind the link is enumerated, so nothing in there is reverted.
    // The scope root itself is still recorded and surfaced: it is a region
    // directory this run could not examine, and saying so is what keeps the
    // next pass from reading an absent scope as an empty one.
    expect(report.confined).toEqual([
      {action: 'reported', path: '.claude/agents', regionId: 'test-region'},
    ]);
    expect(readFileSync(path.join(outside, 'agents/private.env'), 'utf8')).toBe(
      'SECRET=1\n'
    );
  });

  test('12h-iv. content the program moves onto an unexaminable scope path is not deleted as a creation', () => {
    const root = buildRoot();

    mkdirSync(path.join(root, '.claude'), {recursive: true});
    mkdirSync(path.join(root, 'real-agents'), {recursive: true});
    writeFileSync(path.join(root, 'real-agents/one.md'), 'original one\n');
    writeFileSync(path.join(root, 'real-agents/two.md'), 'original two\n');
    writeFileSync(
      path.join(root, 'real-agents/keep.md'),
      'adopter only copy\n'
    );
    // The scope root is a link, so neither pass may enumerate what is behind
    // it. The snapshot is therefore empty for this scope however the run goes.
    symlinkSync(
      path.join(root, 'real-agents'),
      path.join(root, '.claude/agents')
    );
    // De-symlinking with `mv` rather than a fresh `mkdir` is what makes this
    // dangerous: pre-existing content ARRIVES at the scope path between the two
    // passes, so it is present in `after`, absent from `before`, and reads as
    // something the program created. It is the adopter's only copy, and
    // `--backup-dir` would not have covered it either: backups are declared
    // paths only.
    writeScript(
      root,
      [
        'rm .claude/agents',
        'mv real-agents .claude/agents',
        HAPPY_SCRIPT_BODY,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(
      readFileSync(path.join(root, '.claude/agents/keep.md'), 'utf8')
    ).toBe('adopter only copy\n');
    // Recorded present-but-unexaminable, the scope root answers for everything
    // that turns up beneath it, so the arrival is surfaced instead of unlinked.
    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {action: 'reported', path: '.claude/agents', regionId: 'test-region'},
      {
        action: 'reported',
        path: '.claude/agents/keep.md',
        regionId: 'test-region',
      },
    ]);
  });

  test('12h-v. content the program moves onto an in-scope symlinked subdirectory is not deleted as a creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'real-extras'), {recursive: true});
    writeFileSync(
      path.join(root, 'real-extras/keep.md'),
      'adopter only copy\n'
    );
    // Recorded as a link and never descended, so the before pass knows this
    // path exists and nothing about what is inside it. That is the same state
    // an unreadable directory leaves, one level inside the scope root.
    symlinkSync(
      path.join(root, 'real-extras'),
      path.join(root, '.claude/agents/extras')
    );
    writeScript(
      root,
      [
        'rm .claude/agents/extras',
        'mv real-extras .claude/agents/extras',
        HAPPY_SCRIPT_BODY,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(
      readFileSync(path.join(root, '.claude/agents/extras/keep.md'), 'utf8')
    ).toBe('adopter only copy\n');

    const {confined} = report;

    // The link itself cannot be put back over a directory, so it is reported;
    // what matters is that the file that arrived beneath it is reported too
    // rather than unlinked. `mv` moved the only copy, and backups cover
    // declared paths alone.
    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/extras',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/extras/keep.md',
        regionId: 'test-region',
      },
    ]);
  });

  test('12h-vi. the same holds when the in-scope path the program replaces is an ordinary file', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'real-extras'), {recursive: true});
    writeFileSync(
      path.join(root, 'real-extras/keep.md'),
      'adopter only copy\n'
    );
    // A regular file is recorded too, and equally not enumerated: asking only
    // whether an ancestor was UNREADABLE misses both this and the link above,
    // while asking whether the snapshot has an entry at all covers every node
    // the walk did not look inside.
    writeFileSync(path.join(root, '.claude/agents/extras'), 'a plain file\n');
    writeScript(
      root,
      [
        'rm .claude/agents/extras',
        'mv real-extras .claude/agents/extras',
        HAPPY_SCRIPT_BODY,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(
      readFileSync(path.join(root, '.claude/agents/extras/keep.md'), 'utf8')
    ).toBe('adopter only copy\n');

    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/extras',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/extras/keep.md',
        regionId: 'test-region',
      },
    ]);
  });

  test('12i. an in-scope symlink whose target cannot be read is reported, not dropped from the snapshot and then deleted as a creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'outside'), {recursive: true});
    writeFileSync(path.join(root, 'outside/target.txt'), 'TARGET CONTENT\n');
    const linkAbs = path.join(root, '.claude/agents/link.md');

    symlinkSync('../../outside/target.txt', linkAbs);
    // The program never touches the link. The only thing that happens to it is
    // one transient `readlink` failure on the BEFORE pass, which is the whole
    // shape of the defect: the AFTER pass reads it fine.
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    fsControl.failReadlinkOnceFor = '.claude/agents/link.md';

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Presence and restorability are different questions. Dropping the entry
    // answers "was this here before the spawn ran" with "no", and the removal
    // loop then unlinks an adopter's pre-existing link and reports it as a
    // stray write cleaned up. Recording presence with no pre-image keeps that
    // loop honest and leaves the sweep nothing it can write back, which is
    // exactly what `reported` means here.
    expect(report.confined).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/link.md',
        regionId: 'test-region',
      },
    ]);
    expect(lstatSync(linkAbs).isSymbolicLink()).toBe(true);
    expect(readlinkSync(linkAbs)).toBe('../../outside/target.txt');
  });

  test('12j. an in-scope file whose bytes cannot be read is reported, not dropped from the snapshot and then deleted as a creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');

    const privateAbs = path.join(root, '.claude/agents/private.md');

    writeFileSync(privateAbs, 'adopter private\n');
    // Unreadable on the BEFORE pass, readable on the AFTER pass, with no mock
    // anywhere: the program's own `chmod` is what opens it, which is the
    // ordinary shape of this. It needs nothing more exotic than a tool that
    // relaxes permissions it finds too tight.
    chmodSync(privateAbs, 0o000);
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'chmod 644 .claude/agents/private.md'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // A swallowed read failure contributes nothing to `before`, so the removal
    // loop reads the adopter's own file as something the spawn created and
    // unlinks it, reporting the data loss as a stray write cleaned up. Presence
    // with no pre-image is what keeps that loop honest, exactly as for the
    // unreadable link above: the question "was this here" is answered by the
    // entry existing, not by it carrying bytes.
    expect(report.confined).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/private.md',
        regionId: 'test-region',
      },
    ]);
    expect(readFileSync(privateAbs, 'utf8')).toBe('adopter private\n');
  });

  test('12k. an in-scope directory that cannot be read is reported, and nothing inside it is deleted once the program makes it readable', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');

    const vaultAbs = path.join(root, '.claude/agents/vault');
    const vaultNames = ['a.md', 'b.md', 'c.md'];

    mkdirSync(vaultAbs, {recursive: true});
    vaultNames.forEach((name) => {
      writeFileSync(path.join(vaultAbs, name), `${name} original\n`);
    });
    chmodSync(vaultAbs, 0o000);
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'chmod 755 .claude/agents/vault'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));
    const {confined} = report;

    // The before pass could enumerate nothing inside, so all three appear only
    // in `after`. Read as absent-then-present they are three creations, and the
    // removal loop empties the adopter's directory. Recorded present-but-
    // unreadable, the directory answers for everything beneath it, and the
    // whole unverifiable subtree is surfaced instead.
    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/vault',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/vault/a.md',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/vault/b.md',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/vault/c.md',
        regionId: 'test-region',
      },
    ]);
    vaultNames.forEach((name) => {
      expect(readFileSync(path.join(vaultAbs, name), 'utf8')).toBe(
        `${name} original\n`
      );
    });
  });

  test('12k-i. an in-scope entry inside a directory that lists but cannot be searched is reported, not deleted as a creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');

    const lockedAbs = path.join(root, '.claude/agents/locked');
    const insideAbs = path.join(lockedAbs, 'kept.md');

    mkdirSync(lockedAbs, {recursive: true});
    writeFileSync(insideAbs, 'kept original\n');
    // Read but no search: `readdir` returns the name and `lstat` on it fails.
    // This is the one drop arm the mode-000 fixtures above never reach, since
    // there `readdir` itself is what fails.
    chmodSync(lockedAbs, 0o444);
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'chmod 755 .claude/agents/locked'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // The name came back from `readdir`, so something is here; that is the
    // whole of what the before pass knows, and it is enough to keep the
    // removal loop off it.
    expect(report.confined).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/locked/kept.md',
        regionId: 'test-region',
      },
    ]);
    expect(readFileSync(insideAbs, 'utf8')).toBe('kept original\n');
  });

  test('12k-ii. a scope directory whose own parent cannot be searched is reported, and its contents are not deleted once the program restores the bit', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeFileSync(path.join(root, '.claude/agents/adopter.md'), 'adopter\n');
    // The scope root is `.claude/agents`; taking the search bit off `.claude`
    // makes `lstat` on the scope root itself fail, which is one level above
    // every arm inside the walk. The scope then contributes nothing at all,
    // so there is no unreadable directory beneath which its files are
    // sheltered, and restoring the bit makes all of them look newly created.
    chmodSync(path.join(root, '.claude'), 0o600);
    writeScript(root, ['chmod 755 .claude', HAPPY_SCRIPT_BODY].join('\n'));
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));
    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/adopter.md',
        regionId: 'test-region',
      },
    ]);
    expect(
      readFileSync(path.join(root, '.claude/agents/adopter.md'), 'utf8')
    ).toBe('adopter\n');
  });

  test('12l. an in-scope file whose permissions alone the program changes is restored to them', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');

    const secretAbs = path.join(root, '.claude/agents/secret.md');

    writeFileSync(secretAbs, 'private\n');
    chmodSync(secretAbs, 0o600);
    // Content untouched: the mode is the only thing that moves, and it moves
    // the one direction that matters, from private to world-readable.
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, 'chmod 644 .claude/agents/secret.md'].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // Permissions are part of the pre-image, since the restore writes them
    // back. Comparing content alone judges this untouched and leaves the file
    // exposed, which is the one change of this kind the command could undo.
    expect(report.confined).toEqual([
      {
        action: 'restored',
        path: '.claude/agents/secret.md',
        regionId: 'test-region',
      },
    ]);
    expect(statSync(secretAbs).mode.toString(8).slice(-3)).toBe('600');
    expect(readFileSync(secretAbs, 'utf8')).toBe('private\n');
  });

  test('12m. a scope directory nested inside another is snapshotted the same way whichever order the region declares them in', () => {
    const outerFirst = runNestedScopeOrder([
      '.claude/agents/one.md',
      '.claude/agents/sub/two.md',
    ]);
    const innerFirst = runNestedScopeOrder([
      '.claude/agents/sub/two.md',
      '.claude/agents/one.md',
    ]);

    // The walk holds this node's whole pre-image and the scope-root gate holds
    // only "unexaminable", so whichever wrote last used to decide whether the
    // file could be put back at all. Declaration order is not a fact about the
    // tree, and the adopter's bytes are recoverable in both orders or neither.
    expect(outerFirst.content).toBe('adopter bytes\n');
    expect(innerFirst.content).toBe('adopter bytes\n');
    expect(outerFirst.confined).toEqual(innerFirst.confined);
    expect(outerFirst.confined).toContainEqual({
      action: 'restored',
      path: '.claude/agents/sub',
      regionId: 'test-region',
    });
  });

  test('12n. content the program moves onto an in-scope FIFO is not deleted as a creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    mkdirSync(path.join(root, 'real-extras'), {recursive: true});
    writeFileSync(
      path.join(root, 'real-extras/keep.md'),
      'adopter only copy\n'
    );
    // The last node kind the walk meets: not a link, not a directory, not a
    // regular file. It is childless, so the before pass's silence about paths
    // beneath it is true while it is still a FIFO, and false the moment the
    // program replaces it with something that has children. Recording it is
    // what makes this shape behave like 12h-v and 12h-vi rather than differing
    // from them by node kind alone.
    execFileSync('mkfifo', [path.join(root, '.claude/agents/extras')]);
    writeScript(
      root,
      [
        'rm .claude/agents/extras',
        'mv real-extras .claude/agents/extras',
        HAPPY_SCRIPT_BODY,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    expect(
      readFileSync(path.join(root, '.claude/agents/extras/keep.md'), 'utf8')
    ).toBe('adopter only copy\n');

    const {confined} = report;

    expect(confined.toSorted((a, b) => a.path.localeCompare(b.path))).toEqual([
      {
        action: 'reported',
        path: '.claude/agents/extras',
        regionId: 'test-region',
      },
      {
        action: 'reported',
        path: '.claude/agents/extras/keep.md',
        regionId: 'test-region',
      },
    ]);
  });

  test('12n-i. a FIFO the program creates in scope is removed, like any other undeclared creation', () => {
    const root = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      ['mkfifo .claude/agents/pipe', HAPPY_SCRIPT_BODY].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {report} = runCapturing(baseArgv(manifestPath, root));

    // The other side of recording it: a node kind the walk keys is a node kind
    // the removal loop can take, so the spawn cannot leave one behind
    // unreported. Nothing here opens the FIFO, which would block on a writer.
    expect(report.confined).toEqual([
      {action: 'removed', path: '.claude/agents/pipe', regionId: 'test-region'},
    ]);
    expect(existsSync(path.join(root, '.claude/agents/pipe'))).toBe(false);
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

  test('13c. a root nested inside the git repository reports nothing on an ordinary run', () => {
    // `git status --porcelain` always emits paths relative to the repository
    // TOP LEVEL, never to the process cwd. A GAIA project nested inside a
    // larger repository therefore gets every record back carrying the
    // project's own offset, which matches neither the declared set nor the
    // snapshot scope, so the region's own legitimate writes read as
    // out-of-scope ones and the adopter is told to investigate all of them.
    const gitRoot = buildGitRoot();
    const root = path.join(gitRoot, 'project');

    mkdirSync(root, {recursive: true});
    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    execFileSync('git', ['add', '-A'], {cwd: gitRoot});
    execFileSync('git', ['commit', '-q', '-m', 'fixture'], {cwd: gitRoot});

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.confined).toEqual([]);
    expect(readFileSync(path.join(root, DECLARED_PATHS[0]), 'utf8')).toBe(
      'regenerated one\n'
    );
  });

  test('13d. a root nested inside the git repository still reports a genuine out-of-scope write', () => {
    const gitRoot = buildGitRoot();
    const root = path.join(gitRoot, 'project');

    mkdirSync(root, {recursive: true});
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

    execFileSync('git', ['add', '-A'], {cwd: gitRoot});
    execFileSync('git', ['commit', '-q', '-m', 'fixture'], {cwd: gitRoot});

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    // Stripping the offset must not blind the detector: the path is reported
    // relative to the run's own root, which is what every other path in the
    // report is relative to.
    expect(report.confined).toEqual([
      {action: 'reported', path: 'app/', regionId: 'test-region'},
    ]);
  });

  test('13e. a write above the nested root, outside it entirely, is not attributed to the region', () => {
    const gitRoot = buildGitRoot();
    const root = path.join(gitRoot, 'project');

    mkdirSync(root, {recursive: true});
    writeDeclaredFiles(root, 'original');
    writeScript(
      root,
      [HAPPY_SCRIPT_BODY, String.raw`printf "sibling\n" > ../sibling.txt`].join(
        '\n'
      )
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    execFileSync('git', ['add', '-A'], {cwd: gitRoot});
    execFileSync('git', ['commit', '-q', '-m', 'fixture'], {cwd: gitRoot});

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root)
    );

    expect(exit).toBe(0);
    // Every path in the report is relative to the run's own root, so a write
    // above that root has no representation there. It is still a real write
    // the region made, so it leaves by the same non-fatal stderr channel the
    // git-unavailable case uses rather than vanishing.
    expect(report.confined).toEqual([]);
    expect(stderrText).toContain('region_regen_git_delta_out_of_root');
    expect(stderrText).toContain('sibling.txt');
    expect(readFileSync(path.join(gitRoot, 'sibling.txt'), 'utf8')).toBe(
      'sibling\n'
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

  test('13c. an out-of-scope path carrying a space and a non-ASCII byte is reported verbatim, not C-quoted', () => {
    const root = buildGitRoot();

    writeDeclaredFiles(root, 'original');
    // `app/` must already be tracked, else git collapses the whole untracked
    // directory to one `app/` entry and the file name never reaches the parser.
    commitFixture(root, 'app/keep.txt', 'keep\n');
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        String.raw`printf "out of scope\n" > "app/néw file.txt"`,
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.confined).toEqual([
      {action: 'reported', path: 'app/néw file.txt', regionId: 'test-region'},
    ]);
  });

  test('13d. a rename of a non-ASCII out-of-scope path yields both sides unquoted', () => {
    const root = buildGitRoot();

    writeDeclaredFiles(root, 'original');
    commitFixture(root, 'app/ünicode old.txt', 'renamed subject\n');
    // `git mv` stages the rename, so `git status` reports it as a single
    // rename entry rather than a delete plus an untracked add.
    writeScript(
      root,
      [
        HAPPY_SCRIPT_BODY,
        'git mv "app/ünicode old.txt" "app/ünicode new.txt"',
      ].join('\n')
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(
      report.confined.map((entry) => entry.path).toSorted(byLocale)
    ).toEqual(['app/ünicode new.txt', 'app/ünicode old.txt']);
    expect(report.confined.every((entry) => entry.action === 'reported')).toBe(
      true
    );
  });

  test('13e. a fully committed tree, whose first status record is a worktree modification, loses no leading character', () => {
    const root = buildGitRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // Commit everything BEFORE the run. This is the ordinary adopter shape,
    // and it is the one that exercises git's leading status column: a
    // worktree-only modification reports as ` M <path>`, whose first byte is
    // a SPACE. A parser that trims the payload before slicing the 3-char
    // `XY ` prefix eats the path's own first character, and the truncated
    // path then matches neither the declared set nor the snapshot scope, so
    // the region's own legitimate rewrite is reported as an out-of-scope
    // write. `.claude/…` sorts first, so the declared path is the record
    // that lands in position one.
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', 'fixture'], {cwd: root});
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report} = runCapturing(baseArgv(manifestPath, root));

    expect(exit).toBe(0);
    expect(report.confined).toEqual([]);
    expect(report.ran).toHaveLength(1);
    expect(readDeclared(root, 0)).toBe('regenerated one\n');
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

  test('14b. a declared path that is a FIFO is reported rather than opened, so the backup cannot hang the run', () => {
    const root = buildRoot();
    const backupDir = buildRoot();

    writeDeclaredFiles(root, 'original');
    // Writes only two.md. Opening a FIFO for WRITING blocks as surely as
    // opening it for reading, so a regeneration command that wrote to one.md
    // would hang the spawn instead and this test would sit on the 5-minute
    // spawn bound rather than on the backup.
    writeScript(
      root,
      String.raw`printf "regenerated two\n" > .claude/agents/two.md`
    );
    rmSync(path.join(root, DECLARED_PATHS[0]));
    execFileSync('mkfifo', [path.join(root, DECLARED_PATHS[0])]);
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    // Reaching any assertion at all is most of the point: `copyFileSync` on a
    // FIFO with no writer never returns, so the pre-fix shape does not fail
    // here, it never arrives.
    expect(exit).toBe(0);
    expect(report.backedUp).toEqual([DECLARED_PATHS[1]]);
    expect(stderrText).toContain('region_regen_backup_failed');
    expect(stderrText).toContain('not a regular file');
    expect(report.ran).toHaveLength(1);
    expect(existsSync(path.join(backupDir, DECLARED_PATHS[0]))).toBe(false);
  });

  test('14c. a declared path that is a symlink is copied aside as the bytes it resolves to', () => {
    const root = buildRoot();
    const backupDir = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // `sweepScope` skips every declared path in both of its loops, so this
    // backup is the only copy this path ever gets, and the spawn's write goes
    // THROUGH the link to the far end. Holding the target's bytes is therefore
    // the whole value of the copy: a stat that stopped at the link would read
    // "not a regular file" and refuse, leaving the bytes the write destroys
    // held nowhere at all.
    const target = path.join(outside, 'target.md');

    writeFileSync(target, 'out of tree\n');
    rmSync(path.join(root, DECLARED_PATHS[0]));
    symlinkSync(target, path.join(root, DECLARED_PATHS[0]));
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    const backedUpPath = path.join(backupDir, DECLARED_PATHS[0]);

    expect(exit).toBe(0);
    expect(report.backedUp.toSorted(byLocale)).toEqual(SORTED_DECLARED_PATHS);
    expect(stderrText).not.toContain('region_regen_backup_failed');
    expect(lstatSync(backedUpPath).isSymbolicLink()).toBe(false);
    expect(readFileSync(backedUpPath, 'utf8')).toBe('out of tree\n');
    // The premise the copy exists for, asserted rather than assumed: the
    // spawn's write really does land at the far end of the link, out of tree.
    // A later change that declined to spawn over a declared link, or that
    // unlinked instead of truncating, would void it with the copy still green.
    expect(readFileSync(target, 'utf8')).toBe('regenerated one\n');
  });

  test('14d. a link already sitting on a backup key is never written through', () => {
    const root = buildRoot();
    const backupDir = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    writeScript(root, HAPPY_SCRIPT_BODY);
    // The backup directory is shared with the merge walk, which writes declared
    // paths into it, so a link can already hold the key this copy is about to
    // write. `existsSync` follows a dangling one, calls the backup absent, and
    // `copyFileSync` then writes THROUGH the link and lands the bytes at the
    // target's key instead, which for a target outside `backupDir` puts them
    // somewhere nothing will ever look for them.
    mkdirSync(path.dirname(path.join(backupDir, DECLARED_PATHS[0])), {
      recursive: true,
    });
    symlinkSync(
      path.join(outside, 'never-written.md'),
      path.join(backupDir, DECLARED_PATHS[0])
    );
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    expect(exit).toBe(0);
    // The occupied key is left exactly as found, and the OTHER declared path
    // still backs up, so this is a per-key skip rather than an aborted step.
    expect(report.backedUp).toEqual([DECLARED_PATHS[1]]);
    expect(stderrText).not.toContain('region_regen_backup_failed');
    expect(existsSync(path.join(outside, 'never-written.md'))).toBe(false);
    expect(
      lstatSync(path.join(backupDir, DECLARED_PATHS[0])).isSymbolicLink()
    ).toBe(true);
  });

  test('14e. a declared path that is a symlink to a FIFO is reported rather than opened', () => {
    const root = buildRoot();
    const backupDir = buildRoot();
    const outside = buildRoot();

    writeDeclaredFiles(root, 'original');
    // Writes only two.md, for the reason 14b states.
    writeScript(
      root,
      String.raw`printf "regenerated two\n" > .claude/agents/two.md`
    );
    // The hazard reaches the copy through an indirection, so a kind check that
    // stops at the link sees a symlink, calls it backup-able, and hands
    // `copyFileSync` a FIFO to open anyway. Only the FOLLOWED kind refuses it.
    const fifo = path.join(outside, 'pipe');

    execFileSync('mkfifo', [fifo]);
    rmSync(path.join(root, DECLARED_PATHS[0]));
    symlinkSync(fifo, path.join(root, DECLARED_PATHS[0]));
    const manifestPath = writeManifest(root, [buildDeclaration()]);

    const {exit, report, stderrText} = runCapturing(
      baseArgv(manifestPath, root, ['--backup-dir', backupDir])
    );

    // As in 14b, arriving at an assertion at all is most of the point.
    expect(exit).toBe(0);
    expect(report.backedUp).toEqual([DECLARED_PATHS[1]]);
    expect(stderrText).toContain('region_regen_backup_failed');
    expect(stderrText).toContain('not a regular file');
    expect(existsSync(path.join(backupDir, DECLARED_PATHS[0]))).toBe(false);
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

  test.each([
    [{}, 'object'],
    [null, 'null'],
    ['nope', 'string'],
  ])(
    '19a. a regions key of the wrong type (%p) is refused by name, not silently erased into the no-regions case',
    (regions, shape) => {
      const root = buildRoot();
      const manifestPath = writeManifest(root, regions, {});

      const {exit, report} = runCapturing(baseArgv(manifestPath, root));

      expect(exit).toBe(0);
      expect(report.refused).toEqual([
        {
          kind: 'manifest',
          reason: `regions is present but is not an array: ${shape}`,
          regionId: '(manifest)',
        },
      ]);
      expect(report.ran).toEqual([]);
    }
  );

  test.each([
    [['not', 'an', 'object'], 'array'],
    ['a string manifest', 'string'],
    [42, 'number'],
  ])(
    '19b. a manifest whose top level is not an object (%p) is refused, not read as a release that ships no regions',
    (manifest, shape) => {
      const root = buildRoot();
      const manifestPath = path.join(root, 'manifest.json');

      writeFileSync(manifestPath, JSON.stringify(manifest));

      const {exit, report} = runCapturing(baseArgv(manifestPath, root));

      expect(exit).toBe(0);
      expect(report.refused).toEqual([
        {
          kind: 'manifest',
          reason: `manifest top level is not an object: ${shape}`,
          regionId: '(manifest)',
        },
      ]);
      expect(report.ran).toEqual([]);
    }
  );

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
