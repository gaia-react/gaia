/**
 * `GAIA: ` prefix invariant over `.github/workflows/*.yml`.
 *
 * Every maintainer-only workflow (one an adopter clone never receives)
 * carries a `GAIA: ` prefix on its workflow `name:`, so the prefix reads as
 * "this workflow does not exist on an adopter's machine" at a glance.
 * Without a check that is decoration: a new maintainer-only workflow can land
 * unprefixed, or a shipped workflow can gain the prefix by copy-paste, and
 * nothing notices.
 *
 * The authoritative set of "release-excluded workflows an adopter never has"
 * already exists: `buildNeverPresentWorkflowSet` reads `.gaia/release-exclude`.
 * No excluded workflow is installed on an adopter from a template, so every
 * excluded workflow is in that set.
 *
 * The invariant: the set of workflows whose `name:` starts with `GAIA: `
 * equals `buildNeverPresentWorkflowSet(root)`. This test calls the real
 * derive rather than a second copy of it, so the two can never drift apart
 * silently.
 */
import {load as parseYaml} from 'js-yaml';
import {afterEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {resolveExcludePath} from './manifest.js';
import {buildNeverPresentWorkflowSet} from './scrub.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

const GAIA_PREFIX = 'GAIA: ';
const WORKFLOWS_DIR = '.github/workflows';
const RELEASE_EXCLUDE_WORKFLOW_LINE = /^\.github\/workflows\/[^/]+\.yml$/;

// Minimal workflow body for fixtures; `name` is written verbatim, so a caller
// quotes it (or deliberately does not) exactly as it would appear on disk.
const workflowYaml = (name: string, on = 'pull_request'): string =>
  `name: ${name}\non: ${on}\njobs: {}\n`;

const readWorkflowName = (absolutePath: string): unknown => {
  const parsed: unknown = parseYaml(readFileSync(absolutePath, 'utf8'));

  if (typeof parsed !== 'object' || parsed === null || !('name' in parsed)) {
    return undefined;
  }

  return parsed.name;
};

// Repo-relative paths of `.github/workflows/*.yml` whose `name:` starts with
// `GAIA: `. Throws on a `.yaml` sibling (unsupported by the derive) or a YAML
// parse failure (what catches an unquoted `name: GAIA: X`).
const buildPrefixedWorkflowSet = (root: string): Set<string> => {
  const workflowsDirAbsolute = path.join(root, WORKFLOWS_DIR);
  const entries =
    existsSync(workflowsDirAbsolute) ? readdirSync(workflowsDirAbsolute) : [];
  const yamlFiles = entries.filter((fileName) => fileName.endsWith('.yaml'));

  if (yamlFiles.length > 0) {
    throw new Error(
      'assertWorkflowPrefixInvariant: .yaml workflows are unsupported by ' +
        `the release-exclude derive; rename to .yml: ${yamlFiles.join(', ')}`
    );
  }

  const prefixed = new Set<string>();

  for (const fileName of entries.filter((name) => name.endsWith('.yml'))) {
    const relativePath = `${WORKFLOWS_DIR}/${fileName}`;
    let workflowName: unknown;

    try {
      workflowName = readWorkflowName(
        path.join(workflowsDirAbsolute, fileName)
      );
    } catch (error) {
      throw new Error(
        `assertWorkflowPrefixInvariant: failed to parse ${relativePath}: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }

    if (
      typeof workflowName === 'string' &&
      workflowName.startsWith(GAIA_PREFIX)
    ) {
      prefixed.add(relativePath);
    }
  }

  return prefixed;
};

// Expected members missing the prefix (or missing the file itself).
const collectMissingViolations = (
  root: string,
  expected: Set<string>,
  prefixed: Set<string>
): string[] =>
  [...expected]
    .map((relativePath) => {
      if (!existsSync(path.join(root, relativePath))) {
        return `${relativePath}: listed in .gaia/release-exclude but no file on disk`;
      }

      if (!prefixed.has(relativePath)) {
        return (
          `${relativePath}: missing the 'GAIA: ' prefix; add the GAIA: ` +
          'prefix, single-quoted, to its workflow name'
        );
      }

      return undefined;
    })
    .filter((violation): violation is string => violation !== undefined);

// Prefixed paths that should not be: outside the expected set entirely.
const collectStrayViolations = (
  expected: Set<string>,
  prefixed: Set<string>
): string[] =>
  [...prefixed]
    .filter((relativePath) => !expected.has(relativePath))
    .map(
      (relativePath) =>
        `${relativePath}: carries the 'GAIA: ' prefix but is not release-` +
        'excluded; a prefixed workflow must be listed in ' +
        '.gaia/release-exclude, otherwise drop the prefix'
    );

// Throws an Error whose message names every violation and the fix for each.
const assertWorkflowPrefixInvariant = (root: string): void => {
  const expected = buildNeverPresentWorkflowSet(root);

  if (expected.size === 0) {
    throw new Error(
      'assertWorkflowPrefixInvariant: derived an empty maintainer-only ' +
        'workflow set; the derive or .gaia/release-exclude is broken'
    );
  }

  const prefixed = buildPrefixedWorkflowSet(root);
  const violations = [
    ...collectMissingViolations(root, expected, prefixed),
    ...collectStrayViolations(expected, prefixed),
  ];

  if (violations.length > 0) {
    throw new Error(
      `assertWorkflowPrefixInvariant found ${violations.length} ` +
        `violation(s):\n${violations.join('\n')}`
    );
  }
};

type Fixture = {
  root: string;
  writeReleaseExclude: (lines: string[]) => void;
  writeWorkflow: (fileName: string, contents: string) => void;
};

const BASE_RELEASE_EXCLUDE = [
  '.github/workflows/release.yml',
  '.github/workflows/shell-lint.yml',
];

const setupFixture = (): Fixture => {
  const root = mkdtempSync(path.join(tmpdir(), 'wf-prefix-'));
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  mkdirSync(path.join(root, WORKFLOWS_DIR), {recursive: true});

  const fixture: Fixture = {
    root,
    writeReleaseExclude: (lines) => {
      writeFileSync(resolveExcludePath(root), `${lines.join('\n')}\n`, 'utf8');
    },
    writeWorkflow: (fileName, contents) => {
      writeFileSync(path.join(root, WORKFLOWS_DIR, fileName), contents, 'utf8');
    },
  };

  fixture.writeReleaseExclude(BASE_RELEASE_EXCLUDE);
  fixture.writeWorkflow('release.yml', workflowYaml("'GAIA: Release'", 'push'));
  fixture.writeWorkflow('shell-lint.yml', workflowYaml("'GAIA: Shell Lint'"));
  fixture.writeWorkflow('tests.yml', workflowYaml('Tests'));

  return fixture;
};

describe('assertWorkflowPrefixInvariant', () => {
  let fixture: Fixture | undefined;

  afterEach(() => {
    if (fixture) rmSync(fixture.root, {force: true, recursive: true});
    fixture = undefined;
  });

  test('the live tree GAIA: prefix set equals the release-exclude derive', () => {
    expect(() => assertWorkflowPrefixInvariant(REPO_ROOT)).not.toThrow();
  });

  test('the live derive is not a short read', () => {
    const excludeLines = readFileSync(resolveExcludePath(REPO_ROOT), 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => RELEASE_EXCLUDE_WORKFLOW_LINE.test(line));

    expect(excludeLines.length).toBeGreaterThanOrEqual(1);
    expect(buildNeverPresentWorkflowSet(REPO_ROOT).size).toBe(
      excludeLines.length
    );
  });

  test('a clean base fixture does not throw', () => {
    fixture = setupFixture();
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).not.toThrow();
  });

  test('refuses an excluded workflow missing the prefix', () => {
    fixture = setupFixture();
    fixture.writeWorkflow('shell-lint.yml', workflowYaml('Shell Lint'));
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/shell-lint\.yml/
    );
  });

  test('refuses a shipped workflow carrying the prefix', () => {
    fixture = setupFixture();
    fixture.writeWorkflow('tests.yml', workflowYaml("'GAIA: Tests'"));
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/tests\.yml/
    );
  });

  test('refuses an unquoted prefix (YAML parse error)', () => {
    fixture = setupFixture();
    fixture.writeWorkflow('release.yml', workflowYaml('GAIA: Release', 'push'));
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/release\.yml/
    );
  });

  test('refuses an excluded path with no file on disk', () => {
    fixture = setupFixture();
    fixture.writeReleaseExclude([
      ...BASE_RELEASE_EXCLUDE,
      '.github/workflows/gone.yml',
    ]);
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/gone\.yml/
    );
  });

  test('refuses an empty derived set', () => {
    fixture = setupFixture();
    fixture.writeReleaseExclude([]);
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /empty maintainer-only workflow set/
    );
  });

  test('accepts a new maintainer-only workflow added correctly', () => {
    fixture = setupFixture();
    fixture.writeReleaseExclude([
      ...BASE_RELEASE_EXCLUDE,
      '.github/workflows/cli-advisory-scan.yml',
    ]);
    fixture.writeWorkflow(
      'cli-advisory-scan.yml',
      workflowYaml("'GAIA: CLI Advisory Scan'", 'schedule')
    );
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).not.toThrow();
  });
});
