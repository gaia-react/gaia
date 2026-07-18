import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for the `gaia-maintainer release manifest` classifier, exclude
 * parsing, build, and lints.
 *
 * Includes a byte-identity snapshot against the legacy
 * `.gaia/scripts/generate-manifest.mjs` script for the current repo
 * state, plus structural tests for the classifier.
 *
 * The CLI (`run`) tests live in `manifest-cli.test.ts`.
 */
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  buildManifest,
  classifyPath,
  lintClassifierSets,
  lintScanScopes,
  parseExcludePatterns,
  validateExcludeText,
} from './manifest.js';

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

describe('classifyPath', () => {
  test('adopter sentinels return null', () => {
    expect(classifyPath('wiki/hot.md')).toBeNull();
    expect(classifyPath('wiki/log.md')).toBeNull();
    expect(classifyPath('.gaia/VERSION')).toBeNull();
    expect(classifyPath('.gaia/manifest.json')).toBeNull();
  });

  test('shared exact and prefix matches', () => {
    expect(classifyPath('.claude/settings.json')).toBe('shared');
    expect(classifyPath('package.json')).toBe('shared');
    expect(classifyPath('pnpm-workspace.yaml')).toBe('shared');
    expect(classifyPath('CLAUDE.md')).toBe('shared');
    expect(classifyPath('wiki/index.md')).toBe('shared');
    expect(classifyPath('.github/workflows/release.yml')).toBe('shared');
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
    // Root governance files reach the classifier as 'owned' but are
    // filtered out earlier in `buildManifest` by `.gaia/release-exclude`
    // category 11 (maintainer-only project governance).
    expect(classifyPath('CHANGELOG.md')).toBe('owned');
    expect(classifyPath('README.md')).toBe('owned');
    expect(classifyPath('LICENSE')).toBe('owned');
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

  test('matches the literal path and its directory-prefix form, not a glob', () => {
    const patterns = parseExcludePatterns('.claude/commands/gaia-release.md\n');
    expect(patterns[0]?.test('.claude/commands/gaia-release.md')).toBe(true);
    expect(patterns[0]?.test('.claude/commands/other.md')).toBe(false);
  });

  test('treats a literal * as a literal character, never a glob wildcard', () => {
    const patterns = parseExcludePatterns('foo*bar\n');
    expect(patterns[0]?.test('foo*bar')).toBe(true);
    expect(patterns[0]?.test('fooXbar')).toBe(false);
  });
});

describe('validateExcludeText', () => {
  test('accepts an all-literal, unindented exclude body', () => {
    expect(() =>
      validateExcludeText('# comment\n\n.gaia/scripts\nwiki/entities\n')
    ).not.toThrow();
  });

  test('rejects a line containing a glob metacharacter', () => {
    expect(() => validateExcludeText('wiki/meta*\n')).toThrow(/literal/);
  });

  test('rejects a line containing a regex character-class bracket', () => {
    expect(() => validateExcludeText('docs/notes[1]\n')).toThrow(/literal/);
  });

  test('rejects an indented line', () => {
    expect(() => validateExcludeText('  wiki/meta\n')).toThrow(/literal/);
  });

  test('tolerates CRLF line endings on otherwise-valid literal paths', () => {
    expect(() =>
      validateExcludeText('.gaia/cli/src\r\nwiki/entities\r\n')
    ).not.toThrow();
  });

  test('ignores metacharacters inside a comment line', () => {
    expect(() =>
      validateExcludeText('# foo* [bar]\nwiki/entities\n')
    ).not.toThrow();
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
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.2.3\n',
      'app/components/Foo/index.tsx': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
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
    expect(keys).toEqual(keys.toSorted((a, b) => a.localeCompare(b)));

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
      '.gaia/release-exclude': '.gaia/scripts\n',
      '.gaia/scripts/keep-me.mjs': 'console.log("hi");\n',
      '.gaia/VERSION': '0.1.0\n',
      'app/keep.ts': 'export {};\n',
    });

    const manifest = buildManifest(sandbox.root, {
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(manifest.files['.gaia/scripts/keep-me.mjs']).toBeUndefined();
    expect(manifest.files['app/keep.ts']).toBe('owned');
  });

  test('rejects a glob-shaped exclude line loudly instead of silently mis-excluding', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': 'wiki/meta*\n',
      '.gaia/VERSION': '0.1.0\n',
      'app/keep.ts': 'export {};\n',
    });

    expect(() =>
      buildManifest(sandbox.root, {generatedAt: '2026-05-07T00:00:00.000Z'})
    ).toThrow(/literal/);
  });
});

describe('lintClassifierSets', () => {
  test('returns empty when no classifier entry is also excluded', () => {
    const patterns = parseExcludePatterns('.gaia/scripts\nwiki/entities\n');
    expect(lintClassifierSets(patterns)).toEqual([]);
  });

  test('flags exact-set entry that is also excluded', () => {
    const patterns = parseExcludePatterns('CLAUDE.md\n');
    const overlaps = lintClassifierSets(patterns);
    expect(overlaps).toHaveLength(1);
    expect(overlaps[0]).toMatchObject({
      entry: 'CLAUDE.md',
      setName: 'SHARED',
    });
  });

  test('flags prefix-set entry that is also excluded', () => {
    const patterns = parseExcludePatterns('wiki/concepts\n');
    const overlaps = lintClassifierSets(patterns);
    expect(overlaps).toHaveLength(1);
    expect(overlaps[0]).toMatchObject({
      entry: 'wiki/concepts',
      setName: 'WIKI_OWNED_PREFIXES',
    });
  });

  test('flags adopter-sentinel that is also excluded', () => {
    const patterns = parseExcludePatterns('wiki/hot.md\n');
    const overlaps = lintClassifierSets(patterns);
    expect(overlaps).toHaveLength(1);
    expect(overlaps[0]).toMatchObject({
      entry: 'wiki/hot.md',
      setName: 'ADOPTER_OWNED_SENTINELS',
    });
  });
});

describe('lintScanScopes', () => {
  test('returns empty when scope info is unavailable (no release-scrub.yml)', () => {
    const files = {'.gaia/scripts/foo.sh': 'owned' as const};
    expect(lintScanScopes(files, undefined)).toEqual([]);
  });

  test('ignores non-owned and non-.sh manifest entries', () => {
    const files = {
      'app/foo.ts': 'owned' as const,
      'wiki/index.md': 'shared' as const,
    };
    expect(lintScanScopes(files, [])).toEqual([]);
  });

  test('returns empty when an owned .sh file is covered by both scopes', () => {
    // .gaia/scripts is a real SCAN_GLOBS entry; '.gaia/scripts/**' covers it
    // on the maintainer-paths side too.
    const files = {'.gaia/scripts/foo.sh': 'owned' as const};
    expect(lintScanScopes(files, ['.gaia/scripts/**'])).toEqual([]);
  });

  test('flags a directory missing from the maintainer-paths scope only', () => {
    const files = {'.gaia/scripts/foo.sh': 'owned' as const};
    const gaps = lintScanScopes(files, ['.claude/**']);
    expect(gaps).toEqual([
      {dir: '.gaia/scripts', missingFrom: ['maintainer-paths scope']},
    ]);
  });

  test('flags a directory missing from SCAN_GLOBS only', () => {
    // .gaia/new-tool is not one of the real SCAN_GLOBS entries.
    const files = {'.gaia/new-tool/foo.sh': 'owned' as const};
    const gaps = lintScanScopes(files, ['.gaia/new-tool/**']);
    expect(gaps).toEqual([
      {dir: '.gaia/new-tool', missingFrom: ['runtime-deps SCAN_GLOBS']},
    ]);
  });

  test('flags a directory missing from both scopes, sorted by directory', () => {
    const files = {
      '.gaia/new-tool/bar.sh': 'owned' as const,
      '.gaia/other-tool/foo.sh': 'owned' as const,
    };
    const gaps = lintScanScopes(files, []);
    expect(gaps).toEqual([
      {
        dir: '.gaia/new-tool',
        missingFrom: ['maintainer-paths scope', 'runtime-deps SCAN_GLOBS'],
      },
      {
        dir: '.gaia/other-tool',
        missingFrom: ['maintainer-paths scope', 'runtime-deps SCAN_GLOBS'],
      },
    ]);
  });
});

// Materialize the legacy script's path once at module scope: `test.skipIf`
// below needs it at test-definition time, before any test body runs.
const LEGACY_SCRIPT_PATH = path.resolve(
  __dirname,
  '../../../scripts/generate-manifest.mjs'
);

// Seeds a sandbox with a small slice of the real repo layout, picking paths
// that exercise every classifier branch so any drift in either
// implementation manifests as a diff in the output, then builds the manifest
// against it. Shared by both tests below.
const seedManifestSandbox = (): {
  manifest: ReturnType<typeof buildManifest>;
  sandbox: Sandbox;
} => {
  const sandbox = setupSandbox();

  sandbox.commit('seed', {
    '.claude/commands/gaia-init.md': '# init\n',
    '.claude/commands/gaia-release.md': '# release-only\n', // excluded
    '.claude/settings.json': '{}\n',
    '.claude/skills/tdd/SKILL.md': '# tdd\n',
    '.gaia/release-exclude': [
      '# comment',
      '.claude/commands/gaia-release.md',
      '.gaia/scripts',
      '.gaia/release-exclude',
      '.github/CODEOWNERS',
      'CHANGELOG.md',
      'README.md',
      'wiki/entities',
      'wiki/meta',
      '',
    ].join('\n'),
    '.gaia/scripts/legacy.mjs': '// excluded\n', // excluded
    '.gaia/VERSION': '1.0.5\n',
    '.github/CODEOWNERS': '* @maintainer\n',
    '.github/workflows/release.yml': 'name: release\n',
    'app/components/Foo/index.tsx': 'export {};\n',
    'CHANGELOG.md': '# changelog\n', // excluded (root governance, category 11)
    'CLAUDE.md': '# CLAUDE\n',
    'package.json': '{"name":"x"}\n',
    'README.md': '# README\n', // excluded (root governance, category 11)
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

  return {manifest, sandbox};
};

describe('byte-identity vs generate-manifest.mjs', () => {
  // Regression guard on the classifier's category assignments, independent
  // of whether the legacy script is still around to compare against.
  test('classifies every category correctly', () => {
    const {manifest, sandbox} = seedManifestSandbox();

    try {
      expect(manifest.files['CLAUDE.md']).toBe('shared');
      expect(manifest.files['.claude/commands/gaia-init.md']).toBe('owned');
      expect(
        manifest.files['.claude/commands/gaia-release.md']
      ).toBeUndefined();
      expect(manifest.files['.gaia/scripts/legacy.mjs']).toBeUndefined();
      expect(manifest.files['CHANGELOG.md']).toBeUndefined();
      expect(manifest.files['wiki/hot.md']).toBeUndefined();
      expect(manifest.files['wiki/log.md']).toBeUndefined();
      expect(manifest.files['wiki/entities/Skip.md']).toBeUndefined();
      expect(manifest.files['wiki/concepts/Foo.md']).toBe('wiki-owned');
      expect(manifest.files['wiki/overview.md']).toBe('wiki-owned');
      expect(manifest.files['wiki/index.md']).toBe('shared');
      expect(manifest.files['.github/workflows/release.yml']).toBe('shared');
      expect(manifest.files['.github/CODEOWNERS']).toBeUndefined();
    } finally {
      sandbox.cleanup();
    }
  });

  /**
   * Snapshot test: invoke the legacy script and `buildManifest` against
   * the same sandbox. Output must be byte-identical aside from the
   * `generated` timestamp (which we pin in `buildManifest`). Skipped once
   * the legacy script is removed (post-migration); the structural test
   * above remains meaningful as a regression guard on its own.
   */
  test.skipIf(!existsSync(LEGACY_SCRIPT_PATH))(
    'produces same JSON shape as the legacy script',
    () => {
      const {manifest, sandbox} = seedManifestSandbox();

      try {
        // Materialize the legacy script into the sandbox and run it
        // there, so it sees the sandbox's `git ls-files` and reads from
        // the sandbox's `.gaia/VERSION` + `.gaia/release-exclude`.
        const legacyOutput = execFileSync('node', [LEGACY_SCRIPT_PATH], {
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
    }
  );
});
