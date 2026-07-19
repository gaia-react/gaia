import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia-maintainer release manifest` CLI's emit/answer-gate
 * path: `run(...)` (the refusal/answer gate, `--ship`/`--withhold`/
 * `--allow-undecided`, emit, `--out`/`--stdout`).
 *
 * The `--check` report-path tests live in `manifest-cli-check.test.ts`. The
 * flag-grammar tests (argv parsing, flag-combination validation, unknown
 * flags) live in `manifest-cli-args.test.ts`. The classifier / build / lint
 * tests live in `manifest.test.ts`.
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
});
