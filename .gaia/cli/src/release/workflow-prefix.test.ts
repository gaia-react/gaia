/**
 * `GAIA: ` prefix invariant over `.github/workflows/*.yml`.
 *
 * Phase 1 of the workflow-naming plan gave every maintainer-only workflow
 * (one an adopter clone never receives) a `GAIA: ` prefix on its workflow
 * `name:`, so the prefix reads as "this workflow does not exist on an
 * adopter's machine" at a glance. Without a check that is decoration: a new
 * maintainer-only workflow can land unprefixed, or a shipped workflow can
 * gain the prefix by copy-paste, and nothing notices.
 *
 * The authoritative set of "release-excluded workflows an adopter never has"
 * already exists: `buildNeverPresentWorkflowSet` reads `.gaia/release-exclude`
 * and drops any workflow that has a render template under
 * `.gaia/cli/templates/workflows/`, because adopters receive those rendered
 * from the template rather than never at all. `code-review-audit.yml` is the
 * one such workflow today, and it is the plan's declared exception: it stays
 * `name: Code Review Audit`, unprefixed, on purpose.
 *
 * The invariant: the set of workflows whose `name:` starts with `GAIA: `
 * equals `buildNeverPresentWorkflowSet(root)` minus the declared exception,
 * and the declared exception is never prefixed. This test calls the real
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
import {parseExcludeLines} from './manifest.js';
import {buildNeverPresentWorkflowSet} from './scrub.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

const GAIA_PREFIX = 'GAIA: ';
const DECLARED_EXCEPTION = '.github/workflows/code-review-audit.yml';
const WORKFLOWS_DIR = '.github/workflows';
const RELEASE_EXCLUDE_PATH = '.gaia/release-exclude';
const WORKFLOW_TEMPLATES_DIR = '.gaia/cli/templates/workflows';
const RELEASE_EXCLUDE_WORKFLOW_LINE = /^\.github\/workflows\/[^/]+\.yml$/;

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
    .map((relativePath) =>
      relativePath === DECLARED_EXCEPTION ?
        `${relativePath}: is the declared exception and must stay ` +
        "'Code Review Audit' because adopters get a rendered twin"
      : `${relativePath}: carries the 'GAIA: ' prefix but is not release-` +
        'excluded without a .tmpl render template; a prefixed workflow ' +
        'must be release-excluded in .gaia/release-exclude and have no ' +
        '.tmpl render template, otherwise drop the prefix'
    );

// The declared exception must stay listed in release-exclude with its
// render template present; either failing would silently pull it into (or
// keep it out of) the derived set for the wrong reason.
const collectExceptionViolation = (root: string): string | undefined => {
  if (!existsSync(path.join(root, DECLARED_EXCEPTION))) return undefined;

  const excludeLines = parseExcludeLines(
    readFileSync(path.join(root, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const templateAbsolute = path.join(
    root,
    WORKFLOW_TEMPLATES_DIR,
    `${path.basename(DECLARED_EXCEPTION)}.tmpl`
  );

  if (
    excludeLines.includes(DECLARED_EXCEPTION) &&
    existsSync(templateAbsolute)
  ) {
    return undefined;
  }

  return (
    `${DECLARED_EXCEPTION}: exception broken; it must be listed in ` +
    '.gaia/release-exclude and have its .tmpl render template present, or ' +
    'it is either a shipped workflow or wrongly excluded from the derived ' +
    'GAIA: prefix set'
  );
};

// Throws an Error whose message names every violation and the fix for each.
const assertWorkflowPrefixInvariant = (root: string): void => {
  const expected = buildNeverPresentWorkflowSet(root);
  expected.delete(DECLARED_EXCEPTION);

  if (expected.size === 0) {
    throw new Error(
      'assertWorkflowPrefixInvariant: derived an empty maintainer-only ' +
        'workflow set; the derive or .gaia/release-exclude is broken'
    );
  }

  const prefixed = buildPrefixedWorkflowSet(root);
  const exceptionViolation = collectExceptionViolation(root);
  const violations = [
    ...collectMissingViolations(root, expected, prefixed),
    ...collectStrayViolations(expected, prefixed),
    ...(exceptionViolation ? [exceptionViolation] : []),
  ];

  if (violations.length > 0) {
    throw new Error(
      `assertWorkflowPrefixInvariant found ${violations.length} ` +
        `violation(s):\n${violations.join('\n')}`
    );
  }
};

type Fixture = {
  removeTemplate: (fileName: string) => void;
  root: string;
  writeReleaseExclude: (lines: string[]) => void;
  writeWorkflow: (fileName: string, contents: string) => void;
};

const BASE_RELEASE_EXCLUDE = [
  '.github/workflows/release.yml',
  '.github/workflows/shell-lint.yml',
  '.github/workflows/code-review-audit.yml',
];

const setupFixture = (): Fixture => {
  const root = mkdtempSync(path.join(tmpdir(), 'wf-prefix-'));
  mkdirSync(path.join(root, '.gaia'), {recursive: true});
  mkdirSync(path.join(root, WORKFLOW_TEMPLATES_DIR), {recursive: true});
  mkdirSync(path.join(root, WORKFLOWS_DIR), {recursive: true});
  writeFileSync(
    path.join(root, WORKFLOW_TEMPLATES_DIR, 'code-review-audit.yml.tmpl'),
    'name: Code Review Audit\non: pull_request\njobs: {}\n',
    'utf8'
  );

  const fixture: Fixture = {
    removeTemplate: (fileName) => {
      rmSync(path.join(root, WORKFLOW_TEMPLATES_DIR, `${fileName}.tmpl`), {
        force: true,
      });
    },
    root,
    writeReleaseExclude: (lines) => {
      writeFileSync(
        path.join(root, RELEASE_EXCLUDE_PATH),
        `${lines.join('\n')}\n`,
        'utf8'
      );
    },
    writeWorkflow: (fileName, contents) => {
      writeFileSync(path.join(root, WORKFLOWS_DIR, fileName), contents, 'utf8');
    },
  };

  fixture.writeReleaseExclude(BASE_RELEASE_EXCLUDE);
  fixture.writeWorkflow(
    'release.yml',
    "name: 'GAIA: Release'\non: push\njobs: {}\n"
  );
  fixture.writeWorkflow(
    'shell-lint.yml',
    "name: 'GAIA: Shell Lint'\non: pull_request\njobs: {}\n"
  );
  fixture.writeWorkflow(
    'code-review-audit.yml',
    'name: Code Review Audit\non: pull_request\njobs: {}\n'
  );
  fixture.writeWorkflow(
    'tests.yml',
    'name: Tests\non: pull_request\njobs: {}\n'
  );

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
    const excludeLines = readFileSync(
      path.join(REPO_ROOT, RELEASE_EXCLUDE_PATH),
      'utf8'
    )
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => RELEASE_EXCLUDE_WORKFLOW_LINE.test(line));
    const withoutTemplate = excludeLines.filter(
      (line) =>
        !existsSync(
          path.join(
            REPO_ROOT,
            WORKFLOW_TEMPLATES_DIR,
            `${path.basename(line)}.tmpl`
          )
        )
    );

    expect(withoutTemplate.length).toBeGreaterThanOrEqual(1);
    expect(buildNeverPresentWorkflowSet(REPO_ROOT).size).toBe(
      withoutTemplate.length
    );
  });

  test('a clean base fixture does not throw', () => {
    fixture = setupFixture();
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).not.toThrow();
  });

  test('refuses an excluded workflow missing the prefix', () => {
    fixture = setupFixture();
    fixture.writeWorkflow(
      'shell-lint.yml',
      'name: Shell Lint\non: pull_request\njobs: {}\n'
    );
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/shell-lint\.yml/
    );
  });

  test('refuses a shipped workflow carrying the prefix', () => {
    fixture = setupFixture();
    fixture.writeWorkflow(
      'tests.yml',
      "name: 'GAIA: Tests'\non: pull_request\njobs: {}\n"
    );
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /\.github\/workflows\/tests\.yml/
    );
  });

  test('refuses a prefixed declared exception', () => {
    fixture = setupFixture();
    fixture.writeWorkflow(
      'code-review-audit.yml',
      "name: 'GAIA: Code Review Audit'\non: pull_request\njobs: {}\n"
    );
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /declared exception/
    );
  });

  test('refuses an unquoted prefix (YAML parse error)', () => {
    fixture = setupFixture();
    fixture.writeWorkflow(
      'release.yml',
      'name: GAIA: Release\non: push\njobs: {}\n'
    );
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
    fixture.writeReleaseExclude(['.github/workflows/code-review-audit.yml']);
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /empty maintainer-only workflow set/
    );
  });

  test('refuses a broken declared exception', () => {
    fixture = setupFixture();
    fixture.removeTemplate('code-review-audit.yml');
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).toThrow(
      /code-review-audit\.yml/
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
      "name: 'GAIA: CLI Advisory Scan'\non: schedule\njobs: {}\n"
    );
    expect(() => assertWorkflowPrefixInvariant(fixture!.root)).not.toThrow();
  });
});
