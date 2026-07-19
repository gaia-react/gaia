import {describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {parseExcludePatterns, resolveRepoRoot} from './manifest.js';

/**
 * Regression test for #839 (the #679 remainder): three surfaces
 * independently parse `.gaia/release-exclude` into the same anchored-regex
 * semantics — this CLI compiler, the `sed | awk` compile stage that
 * `release.yml` and `build-staging.sh` both carry, and the literal `[ -e ]`
 * presence check in the distribution suite's `01-files-present.sh` (proven
 * against the shell pipeline separately, in
 * `.gaia/tests/distribution/09-exclude-parser-parity.sh`). They currently
 * agree; nothing previously proved they'd stay that way.
 *
 * Reads the compile stage straight out of `release.yml` and
 * `build-staging.sh` at test time (rather than hardcoding a copy), so an
 * edit to either source drifts this test's input, not just its intent.
 */

const repoRoot = resolveRepoRoot(process.cwd());
const releaseYmlPath = path.join(
  repoRoot,
  '.github',
  'workflows',
  'release.yml'
);
const buildStagingPath = path.join(
  repoRoot,
  '.gaia',
  'tests',
  'distribution',
  'lib',
  'build-staging.sh'
);

/**
 * Pull one pipeline stage's command text out of a shell script, keyed by a
 * substring unique to that stage. Strips the leading `|` continuation and
 * trailing `\` line-continuation so the result is a standalone command.
 */
const extractStageCommand = (text: string, marker: string): string => {
  const line = text.split('\n').find((candidate) => candidate.includes(marker));

  if (line === undefined) {
    throw new Error(
      `pipeline stage not found (looked for ${JSON.stringify(marker)})`
    );
  }

  const trimmed = line.trim();
  const withoutContinuation =
    trimmed.endsWith('\\') ? trimmed.slice(0, -1).trim() : trimmed;

  return withoutContinuation.startsWith('|') ?
      withoutContinuation.slice(1).trim()
    : withoutContinuation;
};

/**
 * Stage 1 (comment/blank strip) also carries a trailing file-path argument
 * that differs between the two callers (`.gaia/release-exclude` vs
 * `"$PROJECT_ROOT/.gaia/release-exclude"`); dropping it makes the awk
 * program stdin-friendly and comparable across both files.
 */
const extractAwkProgram = (text: string, marker: string): string => {
  const line = extractStageCommand(text, marker);
  const match = /^awk\s+'([^']*)'/.exec(line);

  if (match === null) {
    throw new Error(`could not isolate awk program from: ${line}`);
  }

  return `awk '${match[1]}'`;
};

const STAGE1_MARKER = "awk '/^[[:space:]]*#/";
const STAGE2_MARKER = "sed 's|[][";
const STAGE3_MARKER = 'awk \'{print "^"';

const releaseYmlText = readFileSync(releaseYmlPath, 'utf8');
const buildStagingText = readFileSync(buildStagingPath, 'utf8');

const releaseYmlStage1 = extractAwkProgram(releaseYmlText, STAGE1_MARKER);
const releaseYmlStage2 = extractStageCommand(releaseYmlText, STAGE2_MARKER);
const releaseYmlStage3 = extractStageCommand(releaseYmlText, STAGE3_MARKER);

const buildStagingStage1 = extractAwkProgram(buildStagingText, STAGE1_MARKER);
const buildStagingStage2 = extractStageCommand(buildStagingText, STAGE2_MARKER);
const buildStagingStage3 = extractStageCommand(buildStagingText, STAGE3_MARKER);

describe('exclude-parser parity (#839)', () => {
  test('release.yml and build-staging.sh compile the exclude-filter pipeline byte-identically', () => {
    // The #679 failure mode this guards: one copy re-diverges (e.g. a
    // reintroduced glob rewrite) while the other stays literal-only.
    expect(buildStagingStage1).toBe(releaseYmlStage1);
    expect(buildStagingStage2).toBe(releaseYmlStage2);
    expect(buildStagingStage3).toBe(releaseYmlStage3);

    // Sanity: prove the markers actually matched real pipeline content,
    // not two equally-empty extractions.
    expect(buildStagingStage2).toContain('sed ');
    expect(buildStagingStage3).toContain('awk ');
  });

  test('CLI-excluded set matches the shell pipeline-excluded set for a representative fixture', () => {
    // Covers: an excluded directory with a child (dir-prefix match), a
    // near-miss sibling that must NOT match (proves the anchor is a real
    // `/`-or-end boundary, not a bare prefix), an excluded file with a `.`
    // (proves `.` is escaped, not treated as regex any-char), a decoy that
    // only differs by that character, and an excluded literal with a `+`
    // (mirrors GAIA's own `app/routes/_public+/`; proves `+` is escaped,
    // not "one-or-more"), plus an untouched path that must survive.
    const excludeFixture =
      '# fixture comment, stripped by stage 1\n' +
      '\n' +
      '.gaia/scripts\n' +
      'CHANGELOG.md\n' +
      'wiki/hot.md\n' +
      'app/routes/_public+\n';

    const candidatePaths = [
      '.gaia/scripts/foo.mjs',
      '.gaia/scriptsOOPS',
      'CHANGELOG.md',
      'wiki/hot.md',
      'wiki/hotXmd',
      'app/routes/_public+/index.tsx',
      'app/keep.ts',
    ];

    // CLI side: a candidate is excluded iff any compiled pattern matches.
    const cliPatterns = parseExcludePatterns(excludeFixture);
    const cliExcluded = candidatePaths
      .filter((candidate) =>
        cliPatterns.some((pattern) => pattern.test(candidate))
      )
      .toSorted((a, b) => a.localeCompare(b));

    // Shell side: the real compile-and-filter pipeline. `grep -vE -f`
    // needs the compiled regex as a file (no stdin form), so stage the
    // compiled output in a scratch dir and run `grep` against the
    // candidate list; whatever `grep` drops (does not keep) is the
    // shell-excluded set.
    const compilePipeline = `${buildStagingStage1} | ${buildStagingStage2} | ${buildStagingStage3}`;
    const compiledRegex = execFileSync('bash', ['-c', compilePipeline], {
      encoding: 'utf8',
      input: excludeFixture,
    });

    const scratchDir = mkdtempSync(path.join(tmpdir(), 'gaia-exclude-parity-'));

    let kept: string[];

    try {
      const compiledRegexPath = path.join(scratchDir, 'exclude-regex.txt');
      writeFileSync(compiledRegexPath, compiledRegex);

      const candidateText = `${candidatePaths.join('\n')}\n`;
      kept = execFileSync('grep', ['-vE', '-f', compiledRegexPath], {
        encoding: 'utf8',
        input: candidateText,
      })
        .split('\n')
        .filter((line) => line.length > 0);
    } finally {
      rmSync(scratchDir, {force: true, recursive: true});
    }

    const shellExcluded = candidatePaths
      .filter((candidate) => !kept.includes(candidate))
      .toSorted((a, b) => a.localeCompare(b));

    expect(cliExcluded).toEqual(shellExcluded);
    // Sanity: the fixture actually exercises exclusion, dot-escaping,
    // plus-escaping, AND the boundary/decoy cases, not a vacuous pass.
    // Order-independent: the assertion above already pins the two sides
    // to each other; this only pins both to the expected content.
    expect(cliExcluded).toHaveLength(4);
    expect(cliExcluded).toEqual(
      expect.arrayContaining([
        '.gaia/scripts/foo.mjs',
        'CHANGELOG.md',
        'app/routes/_public+/index.tsx',
        'wiki/hot.md',
      ])
    );
  });
});
