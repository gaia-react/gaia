import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/**
 * Static text-scan guards for the maintainer-side ship-or-withhold command.
 *
 * This suite is a tripwire, not a proof. A command file can reach the
 * escape hatch second-hand with a single sentence of prose. A static scan
 * of one file cannot enumerate every future indirection; it raises the
 * cost of the bypass and catches the known shapes. The four known shapes
 * are the escape-hatch token, a hand-edit of the boundary, a mutation of
 * the git index, and delegation to a command that carries the token.
 * Those are what it scans for.
 *
 * It imports nothing from `manifest.ts`, runs no CLI, and touches no
 * sandbox: every assertion below reads a committed file's text and matches
 * against it.
 */

const resolveRepoRoot = (): string => {
  // Walk up from this file's location to the repo root (contains .git).
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

const repoRoot = resolveRepoRoot();
const commandPath = path.join(
  repoRoot,
  '.claude',
  'commands',
  'distribution-audit.md'
);
const gaiaReleasePath = path.join(
  repoRoot,
  '.claude',
  'commands',
  'gaia-release.md'
);
const taxonomyPath = path.join(
  repoRoot,
  '.gaia',
  'cli',
  'health',
  'taxonomy.md'
);
const releaseExcludePath = path.join(repoRoot, '.gaia', 'release-exclude');
const gaiaFolderRulePath = path.join(
  repoRoot,
  '.claude',
  'rules',
  'gaia-folder.md'
);

const commandExists = existsSync(commandPath);
const commandText = commandExists ? readFileSync(commandPath, 'utf8') : '';

describe('distribution-audit command file, static guards', () => {
  test('the command file exists (git-tracking is proven downstream, not here)', () => {
    // An earlier draft asserted `git ls-files --error-unmatch` on this path,
    // which fails deterministically: this suite runs before the phase's
    // work is committed, so the file is necessarily untracked at assertion
    // time. Phase 3's staging harness proves tracking by staging from
    // `git ls-files`; a file that never reached the index never reaches
    // staging, so that harness plus assertion 8 below cover the wiring that
    // actually matters.
    expect(commandExists).toBe(true);
  });

  test('never carries the undecided-escape token', () => {
    expect(commandText).not.toContain('--allow-undecided');
  });

  test('never delegates to the release-cutting command by name', () => {
    expect(commandText).not.toContain('gaia-release');
  });

  test('never mutates the git index', () => {
    expect(commandText).not.toContain('git rm');
    expect(commandText).not.toContain('git add');
    expect(commandText).not.toContain('git update-index');
  });

  test('no line both names the boundary file and carries a hand-write vector', () => {
    // The obvious regex here is self-defeating: `/\b(Edit|Write)\b|>>?\s|sed\s+-i/`
    // fails a COMPLIANT file two ways. `>>?\s` matches the leading `> ` of any
    // markdown blockquote, and `\bWrite\b` / `\bEdit\b` match this file's own
    // required prohibition prose (Step 4 must explain why the CLI, never the
    // command, writes the boundary, a sentence that necessarily names the
    // vectors it forbids). Scan instead for a REAL shell redirect that
    // targets the boundary file, and for `sed -i` / `tee` invoked against it
    // on the same line. Prose that forbids a vector must not trip this; only
    // an instruction to use one may.
    const REDIRECT = /(^|\s)>>?\s*\S*release-exclude/;
    const INPLACE = /\b(sed\s+-i|tee)\b[^\n]*release-exclude/;

    const violations = commandText
      .split('\n')
      .filter((line) => line.includes('release-exclude'))
      .filter((line) => REDIRECT.test(line) || INPLACE.test(line));

    expect(violations).toEqual([]);
  });
});

describe('escape-hatch callers, static half', () => {
  // Because refusal is now the CLI's default, omitting either edit below
  // would leave the release path failing on any release cut from a tree
  // containing a new file. These two assertions are the tripwire.
  //
  // Be honest about what this substitutes for: the SPEC's underlying
  // requirement is that the command line in each file, executed verbatim,
  // exits zero and rewrites the manifest. This suite does not execute
  // either line, deliberately: executing either verbatim would rewrite the
  // real tracked manifest, which every task in this plan forbids, and the
  // taxonomy line additionally cannot run verbatim at all, it invokes the
  // bare name `gaia-maintainer`, which is not on PATH (unlike
  // `gaia-release.md`, which invokes `.gaia/cli/gaia-maintainer` by path).
  // Coverage is therefore two halves: a static token assertion here, plus a
  // sandboxed functional equivalent in the CLI's own manifest test suite.

  test('gaia-release.md: every non-check "release manifest" invocation carries the escape hatch', () => {
    const text = readFileSync(gaiaReleasePath, 'utf8');
    const invocationLines = text
      .split('\n')
      .filter((line) => line.includes('release manifest'))
      .filter((line) => !line.includes('--check'));

    expect(invocationLines.length).toBeGreaterThan(0);
    expect(
      invocationLines.filter((line) => !line.includes('--allow-undecided'))
    ).toEqual([]);
  });

  test('taxonomy.md: every non-check "release manifest" invocation carries the escape hatch', () => {
    const text = readFileSync(taxonomyPath, 'utf8');
    const invocationLines = text
      .split('\n')
      .filter((line) => line.includes('release manifest'))
      .filter((line) => !line.includes('--check'));

    expect(invocationLines.length).toBeGreaterThan(0);
    expect(
      invocationLines.filter((line) => !line.includes('--allow-undecided'))
    ).toEqual([]);
  });
});

describe('boundary and allowlist wiring', () => {
  test('.gaia/release-exclude carries the command path as an exact, column-zero line', () => {
    const lines = readFileSync(releaseExcludePath, 'utf8').split('\n');

    expect(lines).toContain('.claude/commands/distribution-audit.md');
  });

  test('every mention in gaia-folder.md sits inside a balanced maintainer-only marker block', () => {
    const START = '<!-- gaia:maintainer-only:start -->';
    const END = '<!-- gaia:maintainer-only:end -->';
    const lines = readFileSync(gaiaFolderRulePath, 'utf8').split('\n');

    let depth = 0;
    let startCount = 0;
    let endCount = 0;
    let mentionCount = 0;
    const outsideMarkers: string[] = [];

    for (const line of lines) {
      if (line.includes(START)) {
        depth += 1;
        startCount += 1;
      }

      if (line.includes('/distribution-audit')) {
        mentionCount += 1;
        if (depth < 1) outsideMarkers.push(line);
      }

      if (line.includes(END)) {
        depth -= 1;
        endCount += 1;
      }
    }

    expect(mentionCount).toBeGreaterThan(0);
    expect(outsideMarkers).toEqual([]);
    expect(startCount).toBe(endCount);
    // The pre-existing pair at the top wraps an unrelated note and is not
    // reused, so the command's own mention needs a second, dedicated pair.
    expect(startCount).toBeGreaterThanOrEqual(2);
  });
});
