import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {ADOPTER_OWNED_SENTINELS as GIT_TRACKED_SENTINELS} from '../release/manifest.js';
import {ADOPTER_OWNED_SENTINELS as RELEASE_SENTINELS} from '../release/runtime-deps.js';
import {
  ADOPTER_OWNED_SENTINELS,
  HELP_TEXT,
  LOCAL_EXEMPT_PREFIX,
  run,
  scanWikiPaths,
} from './dead-paths.js';
import {
  GENERATED_CONTENT_EXEMPT_PATHS,
  WIKI_SCAN_EXEMPT_PREFIXES,
} from './util/markdown-corpus.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-dead-paths-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeFile: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
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

describe('adopter-owned sentinel drift', () => {
  test('exempts exactly the runtime-only sentinels the release scan knows', () => {
    // The two ADOPTER_OWNED_SENTINELS sets are deliberately not shared: this
    // module ships in the adopter `gaia` bundle and `release/runtime-deps.ts`
    // is maintainer-only, so importing across would pull release tooling into
    // the adopter binary (see the constant's comment). That leaves the "a new
    // runtime-created sentinel belongs in both" invariant enforced by prose
    // alone, and a release-side addition that forgets this side silently
    // reintroduces the dead-path false positive. This pins it. Test files are
    // never bundled, so importing the maintainer-only module here costs the
    // adopter binary nothing.
    const runtimeOnly = [...RELEASE_SENTINELS].filter(
      (sentinel) => !GIT_TRACKED_SENTINELS.has(sentinel)
    );

    expect(ADOPTER_OWNED_SENTINELS).toEqual(new Set(runtimeOnly));
  });
});

describe('wiki dead-paths', () => {
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

  test('flags backticked paths to deleted .claude/ files', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/wiki-stop-safety-net.sh` for the safety net.\n'
    );

    const {dead} = scanWikiPaths(sandbox.root);
    expect(dead).toEqual([
      {
        filePath: 'wiki/concepts/Hooks.md',
        line: 3,
        path: '.claude/hooks/wiki-stop-safety-net.sh',
      },
    ]);
  });

  test('ignores paths that exist on disk', () => {
    sandbox.writeFile('.claude/hooks/wiki-session-stop.sh', '#!/bin/bash\n');
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/wiki-session-stop.sh`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('ignores wikilinks and non-path backticks', () => {
    sandbox.writeFile(
      'wiki/concepts/Page.md',
      '# Page\n\nLinks [[Other]] and code `let x = 1;` and constants `FOO_BAR`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('ignores placeholders like `<path>` and globs', () => {
    sandbox.writeFile(
      'wiki/concepts/Page.md',
      '# Page\n\nUse `.claude/hooks/<name>.sh` and `.gaia/cli/src/**/*.ts`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('ignores convention placeholders like SPEC-NNN.md and XXX-XXX.ts', () => {
    sandbox.writeFile(
      'wiki/concepts/Specs.md',
      '# Specs\n\nLives at `.gaia/local/specs/SPEC-NNN.md`. Or `.claude/foo/XXX-bar.ts`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('ignores gitignored runtime paths under .gaia/local', () => {
    sandbox.writeFile(
      'wiki/concepts/Runtime.md',
      '# Runtime\n\nCache at `.gaia/local/cache/shared/update-check.json` and `.gaia/local/i18n.json`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('ignores adopter-owned sentinels absent from the GAIA source repo', () => {
    sandbox.writeFile(
      'wiki/concepts/Project Policy.md',
      '# Project Policy\n\nThe policy lives in `.gaia/project.json`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('exempts the sentinel by exact token, not by prefix', () => {
    // A path that merely extends the sentinel is a distinct, longer token and
    // must still flag. Loosening the `.has()` membership check to a prefix
    // match would suppress it, so this pins the exemption's exactness.
    sandbox.writeFile(
      'wiki/concepts/Project Policy.md',
      '# Project Policy\n\nSee `.gaia/project.json` and `.gaia/project.json.bak`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead.map((d) => d.path)).toEqual([
      '.gaia/project.json.bak',
    ]);
  });

  test('ignores explicit historical-record bullets in decision pages', () => {
    sandbox.writeFile(
      'wiki/decisions/Some Refactor.md',
      [
        '# Some Refactor',
        '',
        '## What changed',
        '',
        '- **Removed** `app/state/theme.tsx`, `app/sessions.server/theme.ts`.',
        '- **Renamed** `app/old/path.ts` → `app/new/path.ts`.',
        '- **Migrated** `app/legacy/foo.ts` to the new location.',
        '',
      ].join('\n')
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('skips wiki/log.md, wiki/hot.md and wiki/meta/** by design', () => {
    sandbox.writeFile(
      'wiki/log.md',
      '# Log\n\nDeleted `.claude/hooks/old.sh` (historical record).\n'
    );
    sandbox.writeFile(
      'wiki/hot.md',
      '# Hot\n\nRecent work moved `.claude/hooks/moved.sh` (session cache).\n'
    );
    sandbox.writeFile(
      'wiki/meta/lint-report.md',
      '# Lint Report\n\nReferences historical `.claude/hooks/gone.sh`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([]);
  });

  test('the help text and the skip list agree, in both directions', () => {
    // The help prose and the array are two hand-written copies of one set, and
    // either can gain or lose a member the other never does (#1878). Both
    // directions are asserted: one of them alone leaves half the drift silent.
    //
    // Array to prose. Every entry of the list below is checked unless named as
    // an exception, so widening a tier is covered by default. What is NOT
    // covered, and this is the honest limit of this direction: the list is
    // rebuilt here from the same three sources `shouldSkipFile` composes, so a
    // FOURTH source added there reaches neither this list nor the help text and
    // both directions stay green. The prose-to-array direction below is the
    // mechanically coupled half; this half is a hand-kept mirror of a
    // three-part composition.
    //
    // `wiki/.state.json` is named as an exception because the markdown corpus
    // collects `.md` files only: no non-markdown entry can ever match a scanned
    // path, so it is unreachable and correctly absent from the help text.
    const exempt: readonly string[] = [
      ...GENERATED_CONTENT_EXEMPT_PATHS,
      ...WIKI_SCAN_EXEMPT_PREFIXES,
      LOCAL_EXEMPT_PREFIX,
    ];
    const notNamedInHelp = new Set([LOCAL_EXEMPT_PREFIX]);
    const documented = exempt.filter(
      (fragment) => !notNamedInHelp.has(fragment)
    );

    for (const fragment of documented) {
      expect(HELP_TEXT).toContain(fragment);
    }

    // Prose to array. Dropping an entry from the array leaves the help
    // promising an exclusion the scan no longer applies, and readers then see
    // dead-path findings for a file the documented contract excludes. Read the
    // exclusion sentence back and require every file it names to still be in
    // the array; a trailing `**` is prose glob notation for the directory
    // prefix the array stores.
    const sentence = /Excludes ([^(]+)\(/.exec(HELP_TEXT)?.[1] ?? '';
    const namedInHelp = [...sentence.matchAll(/wiki\/[\w./*-]+/g)].map(
      (match) => match[0].replaceAll('*', '')
    );

    expect(namedInHelp).toHaveLength(documented.length);

    for (const fragment of namedInHelp) {
      expect(exempt).toContain(fragment);
    }
  });

  test('scans a page whose path merely starts with an exempt page name', () => {
    // The two generated pages are matched exactly rather than by prefix
    // (#1891), which narrows what this scan skips: a page that only starts
    // with one of their names is ordinary hand-edited prose and its dead
    // citations are real rot. The prefix form this scan used before would
    // have swallowed it.
    sandbox.writeFile(
      'wiki/log.md-archive.md',
      '# Archive\n\nSee `.claude/hooks/gone.sh`.\n'
    );

    expect(scanWikiPaths(sandbox.root).dead).toEqual([
      {
        filePath: 'wiki/log.md-archive.md',
        line: 3,
        path: '.claude/hooks/gone.sh',
      },
    ]);
  });

  test('detects dead paths under .gaia/ and app/ as well as .claude/', () => {
    sandbox.writeFile(
      'wiki/concepts/A.md',
      '# A\n\nSee `.gaia/cli/src/missing/index.ts`.\n'
    );
    sandbox.writeFile(
      'wiki/concepts/B.md',
      '# B\n\nSee `app/components/Removed/index.tsx`.\n'
    );

    const {dead} = scanWikiPaths(sandbox.root);
    expect(dead).toHaveLength(2);
    expect(
      dead.map((d) => d.path).toSorted((a, b) => a.localeCompare(b))
    ).toEqual([
      '.gaia/cli/src/missing/index.ts',
      'app/components/Removed/index.tsx',
    ]);
  });

  test('flags sibling-monorepo paths (studio/, website/) regardless of disk', () => {
    sandbox.writeFile(
      'wiki/concepts/Sibling.md',
      '# Sibling\n\nSee `studio/decisions/foo.md`.\nAlso `../../../studio/strategy/bar.md`.\nAnd `website/src/sections/baz.md`.\n'
    );

    const {dead} = scanWikiPaths(sandbox.root);
    expect(
      dead.map((d) => d.path).toSorted((a, b) => a.localeCompare(b))
    ).toEqual([
      '../../../studio/strategy/bar.md',
      'studio/decisions/foo.md',
      'website/src/sections/baz.md',
    ]);
  });

  test('CLI prints `path:line  dead-path` lines on stdout', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\nSee `.claude/hooks/gone.sh`.\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe(
      'wiki/concepts/Hooks.md:3  .claude/hooks/gone.sh'
    );
  });

  test('CLI emits zero stdout when no dead paths', () => {
    sandbox.writeFile('wiki/concepts/Page.md', '# Page\n\nNothing.\n');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('--json emits structured object', () => {
    sandbox.writeFile(
      'wiki/concepts/Hooks.md',
      '# Hooks\n\n`.claude/hooks/gone.sh`\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      dead: readonly {filePath: string; line: number; path: string}[];
    };
    expect(parsed.dead).toHaveLength(1);
    expect(parsed.dead[0]?.path).toBe('.claude/hooks/gone.sh');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('exits 0 when there is no wiki/ directory', () => {
    rmSync(path.join(sandbox.root, 'wiki'), {force: true, recursive: true});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
  });
});
