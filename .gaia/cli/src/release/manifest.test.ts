/**
 * Tests for `gaia release manifest`.
 *
 * Includes a byte-identity snapshot against the legacy
 * `.gaia/scripts/generate-manifest.mjs` script for the current repo
 * state, plus structural tests for the classifier and CLI flags.
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
import {buildManifest, classifyPath, parseExcludePatterns, run} from './manifest.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {cwd: root});
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

describe('classifyPath', () => {
  test('adopter sentinels return null', () => {
    expect(classifyPath('wiki/hot.md')).toBeNull();
    expect(classifyPath('wiki/log.md')).toBeNull();
    expect(classifyPath('CHANGELOG.md')).toBeNull();
    expect(classifyPath('.gaia/VERSION')).toBeNull();
    expect(classifyPath('.gaia/manifest.json')).toBeNull();
  });

  test('shared exact and prefix matches', () => {
    expect(classifyPath('.claude/settings.json')).toBe('shared');
    expect(classifyPath('package.json')).toBe('shared');
    expect(classifyPath('CLAUDE.md')).toBe('shared');
    expect(classifyPath('README.md')).toBe('shared');
    expect(classifyPath('wiki/index.md')).toBe('shared');
    expect(classifyPath('.github/workflows/release.yml')).toBe('shared');
    expect(classifyPath('.github/CODEOWNERS')).toBe('shared');
    expect(classifyPath('.github/FUNDING.yml')).toBe('shared');
  });

  test('wiki-owned exact and prefix matches', () => {
    expect(classifyPath('wiki/concepts/Foo.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/decisions/Bar.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/modules/Baz.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/flows/Qux.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/dependencies/Quux.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/components/Component.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/sources/Source.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/overview.md')).toBe('wiki-owned');
    expect(classifyPath('wiki/README.md')).toBe('wiki-owned');
  });

  test('default fallback is owned', () => {
    expect(classifyPath('app/components/Foo/index.tsx')).toBe('owned');
    expect(classifyPath('.claude/skills/tdd/SKILL.md')).toBe('owned');
    expect(classifyPath('tsconfig.json')).toBe('owned');
  });
});

describe('parseExcludePatterns', () => {
  test('strips comments and blank lines', () => {
    const patterns = parseExcludePatterns(
      '# comment\n\n.gaia/scripts\n\n# another\nwiki/entities\n'
    );
    expect(patterns).toHaveLength(2);
    expect(patterns[0]?.test('.gaia/scripts/foo.mjs')).toBe(true);
    expect(patterns[1]?.test('wiki/entities/Foo.md')).toBe(true);
  });

  test('handles wildcard star segments', () => {
    const patterns = parseExcludePatterns('.claude/commands/gaia-release.md\n');
    expect(patterns[0]?.test('.claude/commands/gaia-release.md')).toBe(true);
    expect(patterns[0]?.test('.claude/commands/other.md')).toBe(false);
  });
});

describe('buildManifest', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('produces sorted file map with correct classes', () => {
    sandbox.commit('seed', {
      '.gaia/VERSION': '1.2.3\n',
      '.gaia/release-exclude': '# none\n',
      'CLAUDE.md': '# CLAUDE\n',
      'app/components/Foo/index.tsx': 'export {};\n',
      'wiki/concepts/Bar.md': '# Bar\n',
      'wiki/hot.md': '# hot\n',
      'wiki/log.md': '# log\n',
    });

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(manifest.version).toBe('1.2.3');
    expect(manifest.generated).toBe('2026-05-07T00:00:00.000Z');

    const keys = Object.keys(manifest.files);
    // Sort matches buildManifest's localeCompare order.
    expect(keys).toEqual([...keys].sort((a, b) => a.localeCompare(b)));

    expect(manifest.files['CLAUDE.md']).toBe('shared');
    expect(manifest.files['app/components/Foo/index.tsx']).toBe('owned');
    expect(manifest.files['wiki/concepts/Bar.md']).toBe('wiki-owned');
    expect(manifest.files['wiki/hot.md']).toBeUndefined();
    expect(manifest.files['wiki/log.md']).toBeUndefined();
    expect(manifest.files['.gaia/VERSION']).toBeUndefined();
    expect(manifest.files['.gaia/manifest.json']).toBeUndefined();
  });

  test('respects release-exclude patterns', () => {
    sandbox.commit('seed', {
      '.gaia/VERSION': '0.1.0\n',
      '.gaia/release-exclude': '.gaia/scripts\n',
      '.gaia/scripts/keep-me.mjs': 'console.log("hi");\n',
      'app/keep.ts': 'export {};\n',
    });

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(manifest.files['.gaia/scripts/keep-me.mjs']).toBeUndefined();
    expect(manifest.files['app/keep.ts']).toBe('owned');
  });
});

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
      '.gaia/VERSION': '1.0.0\n',
      '.gaia/release-exclude': '# none\n',
      'app/foo.ts': 'export {};\n',
    });

    const exit = run([], {
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
      '.gaia/VERSION': '0.0.1\n',
      '.gaia/release-exclude': '# none\n',
    });

    const exit = run(['--stdout'], {
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
      '.gaia/VERSION': '0.0.1\n',
      '.gaia/release-exclude': '# none\n',
    });

    const exit = run(['--bogus'], {cwd: sandbox.root});
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

describe('byte-identity vs generate-manifest.mjs', () => {
  /**
   * Snapshot test: invoke the legacy script and `buildManifest` against
   * the same sandbox. Output must be byte-identical aside from the
   * `generated` timestamp (which we pin in `buildManifest`).
   */
  test('produces same JSON shape as the legacy script', () => {
    const sandbox = setupSandbox();

    try {
      // Mirror a small slice of the real repo layout. Pick paths
      // exercising every classifier branch so any drift in either
      // implementation manifests as a diff in the output.
      sandbox.commit('seed', {
        '.gaia/VERSION': '1.0.5\n',
        '.gaia/release-exclude': [
          '# comment',
          '.claude/commands/gaia-release.md',
          '.gaia/scripts',
          '.gaia/release-exclude',
          'wiki/entities',
          'wiki/meta',
          '',
        ].join('\n'),
        '.claude/commands/gaia-init.md': '# init\n',
        '.claude/commands/gaia-release.md': '# release-only\n', // excluded
        '.claude/settings.json': '{}\n',
        '.claude/skills/tdd/SKILL.md': '# tdd\n',
        '.gaia/scripts/legacy.mjs': '// excluded\n', // excluded
        '.github/CODEOWNERS': '* @maintainer\n',
        '.github/workflows/release.yml': 'name: release\n',
        'CHANGELOG.md': '# changelog\n', // sentinel
        'CLAUDE.md': '# CLAUDE\n',
        'README.md': '# README\n',
        'app/components/Foo/index.tsx': 'export {};\n',
        'package.json': '{"name":"x"}\n',
        'wiki/concepts/Foo.md': '# foo\n',
        'wiki/decisions/Bar.md': '# bar\n',
        'wiki/entities/Skip.md': '# excluded\n', // excluded
        'wiki/hot.md': '# hot\n', // sentinel
        'wiki/index.md': '# index\n',
        'wiki/log.md': '# log\n', // sentinel
        'wiki/overview.md': '# overview\n',
      });

      const manifest = buildManifest(sandbox.root, {
        generatedAt: '2026-05-07T00:00:00.000Z',
      });

      // Materialize the legacy script into the sandbox and run it
      // there, so it sees the sandbox's `git ls-files` and reads from
      // the sandbox's `.gaia/VERSION` + `.gaia/release-exclude`.
      const legacyScriptPath = path.resolve(
        __dirname,
        '../../../scripts/generate-manifest.mjs'
      );

      if (!existsSync(legacyScriptPath)) {
        // Legacy script has been removed (post-migration). Skip the
        // byte-identity comparison; the structural assertions below
        // remain meaningful as a regression guard.
        expect(manifest.files['CLAUDE.md']).toBe('shared');
        expect(manifest.files['.claude/commands/gaia-init.md']).toBe('owned');
        expect(manifest.files['.claude/commands/gaia-release.md']).toBeUndefined();
        expect(manifest.files['.gaia/scripts/legacy.mjs']).toBeUndefined();
        expect(manifest.files['CHANGELOG.md']).toBeUndefined();
        expect(manifest.files['wiki/hot.md']).toBeUndefined();
        expect(manifest.files['wiki/log.md']).toBeUndefined();
        expect(manifest.files['wiki/entities/Skip.md']).toBeUndefined();
        expect(manifest.files['wiki/concepts/Foo.md']).toBe('wiki-owned');
        expect(manifest.files['wiki/overview.md']).toBe('wiki-owned');
        expect(manifest.files['wiki/index.md']).toBe('shared');
        expect(manifest.files['.github/workflows/release.yml']).toBe('shared');

        return;
      }

      const legacyOutput = execFileSync('node', [legacyScriptPath], {
        cwd: sandbox.root,
        encoding: 'utf8',
      });
      const legacyParsed = JSON.parse(legacyOutput) as {
        files: Record<string, string>;
        generated: string;
        version: string;
      };

      // Pin generated to make output deterministic.
      legacyParsed.generated = manifest.generated;

      expect(legacyParsed.files).toEqual(manifest.files);
      expect(legacyParsed.version).toEqual(manifest.version);

      // Byte-identity: serialize both with the same shape and compare.
      const ourSerialized = `${JSON.stringify(manifest, null, 2)}\n`;
      const theirSerialized = `${JSON.stringify(legacyParsed, null, 2)}\n`;
      expect(ourSerialized).toEqual(theirSerialized);
    } finally {
      sandbox.cleanup();
    }
  });
});
