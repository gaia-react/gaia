import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia-maintainer release manifest` CLI: `run(...)`
 * (`--check` reporting, the refusal/answer gate, flag parsing, emit,
 * `--out`/`--stdout`, `--allow-undecided`).
 *
 * The classifier / build / lint tests live in `manifest.test.ts`.
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

  test('writes .gaia/manifest.json by default', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
    });

    // Bootstrapping a manifest from nothing means every classified path is
    // unanswered, which the refusal gate declines by default. The escape
    // hatch is what the bare command no longer is.
    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);

    const manifestPath = path.join(sandbox.root, '.gaia', 'manifest.json');
    expect(existsSync(manifestPath)).toBe(true);
    const written = readFileSync(manifestPath, 'utf8');
    expect(written.endsWith('\n')).toBe(true);
    const parsed = JSON.parse(written) as Record<string, unknown>;
    expect(parsed.version).toBe('1.0.0');
    expect(parsed.generated).toBe('2026-05-07T00:00:00.000Z');

    const summary = stdio.outputs.join('');
    expect(summary).toContain('release manifest:');
    expect(summary).toContain('owned=');
  });

  test('--stdout prints to stdout without writing file', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '0.0.1\n',
    });

    const exit = run(['--stdout', '--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);

    const out = stdio.outputs.join('');
    const parsed = JSON.parse(out) as Record<string, unknown>;
    expect(parsed.version).toBe('0.0.1');

    const manifestPath = path.join(sandbox.root, '.gaia', 'manifest.json');
    expect(existsSync(manifestPath)).toBe(false);
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

  test('fails gracefully when VERSION is missing', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      'README.md': '# r\n',
    });
    rmSync(path.join(sandbox.root, '.gaia/release-exclude'), {force: true});

    const exit = run(['--stdout'], {cwd: sandbox.root});
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_build_failed');
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

  const seedAndGenerate = (extraFiles: Record<string, string> = {}): void => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
      'wiki/concepts/Bar.md': '# bar\n',
      'wiki/index.md': '# index\n',
      ...extraFiles,
    });

    // No committed manifest yet, so every classified path is unanswered; the
    // escape hatch is how a manifest gets bootstrapped from nothing.
    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;
  };

  test('clean case: exits 0 with empty diff', () => {
    seedAndGenerate();

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
    expect(stdio.errors.join('')).toBe('');
  });

  test('missing entry: exits non-zero and names the missing file', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, unknown>;
    };
    delete manifest.files['app/foo.ts'];
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('newly ship');
    expect(out).toContain('app/foo.ts');
    expect(out).toContain('--ship');
    expect(out).toContain('--withhold');
    expect(out).toContain('does not withhold');
  });

  test('extra entry: exits non-zero and names the extra file', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/ghost.ts'] = 'owned';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('extra in manifest');
    expect(out).toContain('app/ghost.ts');
  });

  test('classification drift: exits non-zero and names the drift', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/foo.ts'] = 'shared';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('class drift');
    expect(out).toContain('app/foo.ts');
    expect(out).toContain('shared → owned');
  });

  test('version drift: exits non-zero and names both versions', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
      version: string;
    };
    manifest.version = '0.9.0';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('version drift');
    expect(out).toContain('0.9.0');
    expect(out).toContain('1.0.0');
  });

  test('malformed manifest (not an object): exits 2 with a parse error', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    writeFileSync(manifestPath, '["not", "a", "manifest"]\n', 'utf8');

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_parse_failed');
    expect(stdio.errors.join('')).toContain('malformed');
  });

  test('malformed manifest (bad class value): exits 2 with a parse error', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/foo.ts'] = 'bogus-class';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_parse_failed');
  });

  test('glob-shaped release-exclude line: exits 2 loudly instead of silently mis-excluding', () => {
    seedAndGenerate();

    writeFileSync(
      path.join(sandbox.root, '.gaia/release-exclude'),
      'app/foo*\n',
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_build_failed');
    expect(stdio.errors.join('')).toContain('literal');
  });

  test('indented release-exclude line: exits 2 loudly', () => {
    seedAndGenerate();

    writeFileSync(
      path.join(sandbox.root, '.gaia/release-exclude'),
      '  app/foo\n',
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_build_failed');
  });

  test('missing manifest file: exits non-zero with manifest_missing error', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
    });

    const exit = run(['--check'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('manifest_missing');
    // The remedy it names must be one that actually works: the bare command
    // refuses on any tree carrying a classified file.
    expect(stdio.errors.join('')).toContain(
      'gaia-maintainer release manifest --allow-undecided'
    );
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

  test('--check --json emits structured report', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/extra.ts'] = 'owned';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check', '--json'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const parsed = JSON.parse(stdio.outputs.join('')) as ManifestDriftJson;
    expect(parsed.extra).toEqual([{actual: 'owned', file: 'app/extra.ts'}]);
    expect(parsed.missing).toEqual([]);
    expect(parsed.drift).toEqual([]);
  });

  test('classifier-set overlap: exits non-zero and names the overlap', () => {
    sandbox.commit('seed', {
      // CLAUDE.md is in the SHARED classifier set; if release-exclude
      // also matches it, the SHARED entry is dead code.
      '.gaia/release-exclude': 'CLAUDE.md\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('classifier-set overlaps');
    expect(out).toContain('SHARED');
    expect(out).toContain('CLAUDE.md');
  });

  test('scan-scope gap: exits non-zero and names the uncovered directory', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      // .gaia/scripts is a real runtime-deps SCAN_GLOBS entry, but this
      // maintainer-paths scope omits it, so it's covered on one side only.
      '.gaia/release-scrub.yml': [
        'transforms:',
        '  - type: leak-check',
        '    checks:',
        '      - id: maintainer-paths',
        '        description: test',
        '        pattern: "test"',
        '        scope:',
        '          - "CLAUDE.md"',
        '',
      ].join('\n'),
      '.gaia/scripts/foo.sh': '#!/bin/sh\n',
      '.gaia/VERSION': '1.0.0\n',
      'CLAUDE.md': '# CLAUDE\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('.sh-bearing directories outside a leak-check scope');
    expect(out).toContain('.gaia/scripts');
    expect(out).toContain('maintainer-paths scope');
  });

  test('scan-scope clean: covered .sh directory does not trip the check', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/release-scrub.yml': [
        'transforms:',
        '  - type: leak-check',
        '    checks:',
        '      - id: maintainer-paths',
        '        description: test',
        '        pattern: "test"',
        '        scope:',
        '          - ".gaia/scripts/**"',
        '',
      ].join('\n'),
      '.gaia/scripts/foo.sh': '#!/bin/sh\n',
      '.gaia/VERSION': '1.0.0\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
  });
});

type ManifestDriftJson = {
  drift: {actual: string; expected: string; file: string}[];
  extra: {actual: string; file: string}[];
  missing: {expected: string; file: string}[];
};

const GENERATED_AT = '2026-05-07T00:00:00.000Z';

// A hand-written copy of the real boundary file's shape. The live
// `.gaia/release-exclude` is what a maintainer edits every time they withhold
// something, so asserting against it would test today's distribution boundary
// instead of the gate.
const ANSWER_EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '',
  '# --- 1. Maintainer-only Claude surface ---',
  '# Commands only the maintainer ever runs.',
  '.claude/commands/gaia-release.md',
  '',
  '# --- 2. Maintainer-only wiki content ---',
  '# Internal vault administration.',
  'wiki/entities',
  '',
].join('\n');

/**
 * The refusal gate: `release manifest` produces manifest content, in any
 * output mode, only once every file that would newly ship carries an explicit
 * ship-or-withhold answer.
 */
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

  const excludePath = (): string =>
    path.join(sandbox.root, '.gaia/release-exclude');

  const manifestPath = (): string =>
    path.join(sandbox.root, '.gaia/manifest.json');

  const readBoundaryAndManifest = (): {exclude: string; manifest: string} => ({
    exclude: readFileSync(excludePath(), 'utf8'),
    manifest: readFileSync(manifestPath(), 'utf8'),
  });

  const readManifestFiles = (): Record<string, string> =>
    (
      JSON.parse(readFileSync(manifestPath(), 'utf8')) as {
        files: Record<string, string>;
      }
    ).files;

  const runGate = (argv: readonly string[]): number =>
    run(argv, {cwd: sandbox.root, generatedAt: GENERATED_AT});

  /**
   * Bootstrap a fully-acknowledged manifest, then commit `unanswered` on top,
   * so `missing` holds exactly those paths. Returns the pre-run bytes of both
   * files, which every refusal case asserts are unchanged afterwards.
   */
  const seedWithUnanswered = (
    unanswered: Record<string, string>,
    baseExtra: Record<string, string> = {}
  ): {exclude: string; manifest: string} => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': ANSWER_EXCLUDE_FIXTURE,
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      ...baseExtra,
    });
    expect(runGate(['--allow-undecided'])).toBe(0);
    sandbox.commit('add unanswered files', unanswered);
    stdio.outputs.length = 0;
    stdio.errors.length = 0;

    return readBoundaryAndManifest();
  };

  test('refuses by default while a newly-shipping file is unanswered', () => {
    const before = seedWithUnanswered({
      '.gaia/statusline/example.sh': '#!/bin/sh\n',
    });

    expect(runGate([])).toBe(1);
    expect(readBoundaryAndManifest()).toEqual(before);

    const errors = stdio.errors.join('');
    expect(errors).toContain('unanswered_paths');
    expect(errors).toContain('.gaia/statusline/example.sh');
  });

  test('--ship answers a path and the rewritten manifest lists it', () => {
    const before = seedWithUnanswered({'app/new.ts': 'export {};\n'});

    expect(runGate(['--ship', 'app/new.ts'])).toBe(0);
    expect(['owned', 'shared', 'wiki-owned']).toContain(
      readManifestFiles()['app/new.ts']
    );
    expect(readFileSync(excludePath(), 'utf8')).toBe(before.exclude);
  });

  test('--withhold writes a verbatim column-zero line inside its category', () => {
    seedWithUnanswered({'.gaia/statusline/example.sh': '#!/bin/sh\n'});

    expect(
      runGate([
        '--withhold',
        '.gaia/statusline/example.sh',
        '--category',
        '1',
        '--reason',
        'maintainer-only',
      ])
    ).toBe(0);

    const lines = readFileSync(excludePath(), 'utf8').split('\n');
    // An exact whole-line match IS the column-zero assertion: any leading
    // whitespace and `indexOf` misses.
    const pathIndex = lines.indexOf('.gaia/statusline/example.sh');

    expect(pathIndex).toBeGreaterThan(-1);
    expect(lines[pathIndex - 1]).toBe('# maintainer-only');
    expect(pathIndex).toBeGreaterThan(
      lines.findIndex((line) => line.startsWith('# --- 1.'))
    );
    expect(pathIndex).toBeLessThan(
      lines.findIndex((line) => line.startsWith('# --- 2.'))
    );
    expect(readManifestFiles()['.gaia/statusline/example.sh']).toBeUndefined();
  });

  test('a bare directory is rejected by membership, not by metacharacters', () => {
    const before = seedWithUnanswered(
      {'wiki/decisions/Foo.md': '# foo\n'},
      {'wiki/decisions/Bar.md': '# bar\n'}
    );

    expect(
      runGate([
        '--withhold',
        'wiki/decisions',
        '--category',
        '2',
        '--reason',
        'internal',
      ])
    ).not.toBe(0);
    expect(readBoundaryAndManifest()).toEqual(before);
    expect(stdio.errors.join('')).toContain('answer_not_missing');
  });

  test('a withhold path carrying a regex metacharacter is rejected', () => {
    const before = seedWithUnanswered({'docs/notes[1].md': '# notes\n'});

    expect(
      runGate([
        '--withhold',
        'docs/notes[1].md',
        '--category',
        '1',
        '--reason',
        'x',
      ])
    ).not.toBe(0);
    expect(readBoundaryAndManifest()).toEqual(before);
    expect(stdio.errors.join('')).toContain('withhold_metacharacter');
  });

  test('the refusal gates --stdout and --out, not just the default write', () => {
    const before = seedWithUnanswered({'app/new.ts': 'export {};\n'});
    const outPath = path.join(sandbox.root, 'out.json');

    expect(runGate(['--stdout'])).not.toBe(0);
    expect(stdio.outputs.join('')).toBe('');

    expect(runGate(['--out', outPath])).not.toBe(0);
    expect(existsSync(outPath)).toBe(false);
    expect(stdio.outputs.join('')).toBe('');
    expect(readBoundaryAndManifest()).toEqual(before);
  });

  test('one invocation mixes --ship and --withhold, leaving no drift', () => {
    seedWithUnanswered({
      'app/a.ts': 'export {};\n',
      'app/b.ts': 'export {};\n',
    });

    expect(
      runGate([
        '--ship',
        'app/a.ts',
        '--withhold',
        'app/b.ts',
        '--category',
        '1',
        '--reason',
        'r',
      ])
    ).toBe(0);

    expect(readFileSync(excludePath(), 'utf8').split('\n')).toContain(
      'app/b.ts'
    );

    const files = readManifestFiles();
    expect(files['app/a.ts']).toBe('owned');
    expect(files['app/b.ts']).toBeUndefined();

    stdio.outputs.length = 0;
    expect(runGate(['--check', '--json'])).toBe(0);

    const report = JSON.parse(stdio.outputs.join('')) as ManifestDriftJson;
    expect(report.missing).toEqual([]);
  });

  test('an individually-valid withhold is not written while another file is unanswered', () => {
    const before = seedWithUnanswered({
      'app/a.ts': 'export {};\n',
      'app/b.ts': 'export {};\n',
    });

    // Validate-before-write: the withhold is fine on its own, but `app/b.ts`
    // has no answer, so the whole set is refused and neither file moves.
    expect(
      runGate(['--withhold', 'app/a.ts', '--category', '1', '--reason', 'r'])
    ).not.toBe(0);
    expect(readBoundaryAndManifest()).toEqual(before);
    expect(stdio.errors.join('')).toContain('unanswered_paths');
  });

  test('--allow-undecided ships every unanswered file', () => {
    seedWithUnanswered({
      'app/new.ts': 'export {};\n',
      'docs/guide.md': '# guide\n',
    });

    expect(runGate(['--allow-undecided'])).toBe(0);

    const files = readManifestFiles();
    expect(files['app/new.ts']).toBe('owned');
    expect(files['docs/guide.md']).toBe('owned');
  });

  test('--allow-undecided regenerates cleanly: the follow-up --check is clean', () => {
    seedWithUnanswered({'app/new.ts': 'export {};\n'});

    expect(runGate(['--allow-undecided'])).toBe(0);
    stdio.outputs.length = 0;

    expect(runGate(['--check'])).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
  });

  test.each([
    ['a newline', 'internal\nwiki/decisions'],
    ['a carriage return', 'internal\rwiki/decisions'],
  ])(
    'a withhold reason carrying %s is rejected and appends nothing',
    (_label, reason) => {
      const before = seedWithUnanswered({'app/new.ts': 'export {};\n'});

      expect(
        runGate([
          '--withhold',
          'app/new.ts',
          '--category',
          '1',
          '--reason',
          reason,
        ])
      ).not.toBe(0);
      expect(readBoundaryAndManifest()).toEqual(before);
      // The smuggled second line would have been an uncommented, subtree-
      // masking exclude entry that membership never inspected, because
      // membership only ever looks at the withhold value.
      expect(readFileSync(excludePath(), 'utf8').split('\n')).not.toContain(
        'wiki/decisions'
      );
      expect(stdio.errors.join('')).toContain('withhold_reason_invalid');
    }
  );

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
