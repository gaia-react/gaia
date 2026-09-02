/**
 * Strategy: `extractLiterals` runs against fixture strings only, never against
 * the repository. `run` reads whatever tree it is pointed at, and a vitest
 * assertion over the LIVE tree would red the quality gate for a state the
 * label migrations retire on purpose, so the live scan stays a CI command and
 * never a test. The one block that calls `run` points it at a throwaway
 * fixture repository instead, which that rule does not reach.
 *
 * Every negative fixture below is copied from a real site in the tree. The
 * English words are what a bare `--label` scan harvests out of test names,
 * help text, and error strings; the invalid-vocabulary spellings come from the
 * debt-metadata suite, which feeds them deliberately to prove its validator
 * rejects them.
 */
import {afterAll, beforeAll, describe, expect, test, vi} from 'vitest';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  NON_ASCII_STEM,
  QUOTED_FIRST_BYTE,
  QUOTEPATH_PIN_ARGS,
} from '../../util/non-ascii-path-fixture.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {extractLiterals, literalProblem, run, SCAN_EXCLUDED} from '../check.js';
import {readRegistry} from '../registry.js';

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

const namesIn = (filePath: string, text: string): string[] =>
  extractLiterals(filePath, text).map((literal) => literal.name);

const SHELL = 'script.sh';

/**
 * `run`'s exit code paired with what it wrote to stdout, which it writes
 * directly rather than returning.
 */
const captureRun = (argv: readonly string[]): {code: number; out: string} => {
  let out = '';
  const spy = vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
    out += String(chunk);

    return true;
  });

  try {
    const code = run(argv);

    return {code, out};
  } finally {
    spy.mockRestore();
  }
};

describe('labels/check extraction forms', () => {
  test('form 1: a bare and a quoted --label', () => {
    expect(namesIn(SHELL, 'gh issue create --label tech-debt')).toEqual([
      'tech-debt',
    ]);
    expect(namesIn(SHELL, 'gh issue create --label "tech-debt"')).toEqual([
      'tech-debt',
    ]);
    expect(namesIn(SHELL, "gh issue create --label 'tech-debt'")).toEqual([
      'tech-debt',
    ]);
  });

  test('form 2: --add-label and --remove-label', () => {
    expect(namesIn(SHELL, 'gh issue edit 1 --add-label in-progress')).toEqual([
      'in-progress',
    ]);
    expect(
      namesIn(SHELL, 'gh issue edit 1 --remove-label in-progress')
    ).toEqual(['in-progress']);
  });

  test('form 3: comma-joined values split', () => {
    expect(namesIn(SHELL, 'gh pr create --label gaia-ci,security')).toEqual([
      'gaia-ci',
      'security',
    ]);
    expect(namesIn(SHELL, 'gh pr create --labels "gaia-ci,security"')).toEqual([
      'gaia-ci',
      'security',
    ]);
  });

  test('form 4: the positional name of gh label create, edit, and delete', () => {
    expect(
      namesIn(SHELL, 'gh label create needs-human --color d93f0b')
    ).toEqual(['needs-human']);
    expect(namesIn(SHELL, 'gh label edit wontfix --color e5e5e5')).toEqual([
      'wontfix',
    ]);
    expect(namesIn(SHELL, 'gh label delete run-audit --yes')).toEqual([
      'run-audit',
    ]);
  });

  test('form 5: an issue template labels array', () => {
    expect(
      namesIn('.github/ISSUE_TEMPLATE/bug_report.yml', 'labels: [bug]')
    ).toEqual(['bug']);
    expect(
      namesIn(
        '.github/ISSUE_TEMPLATE/feature_request.yml',
        'labels: [enhancement, bug]'
      )
    ).toEqual(['enhancement', 'bug']);
  });

  test('form 5 is pinned: the same line in another YAML file yields nothing', () => {
    expect(namesIn('.github/workflows/other.yml', 'labels: [bug]')).toEqual([]);
  });

  test('form 6: a *_label property in the workflow-vars module', () => {
    expect(
      namesIn(
        '.gaia/cli/src/automation/workflow-vars.ts',
        "    pr_label: 'gaia-ci',"
      )
    ).toEqual(['gaia-ci']);
  });

  test('form 6 skips a type declaration with no string literal', () => {
    expect(
      namesIn(
        '.gaia/cli/src/automation/workflow-vars.ts',
        '  needs_human_review_label: string;'
      )
    ).toEqual([]);
  });

  test('form 7: the run-audit override default in the config reader', () => {
    expect(
      namesIn(
        '.gaia/scripts/read-audit-ci-config.sh',
        'DEFAULT_OVERRIDE_LABEL="run-audit"'
      )
    ).toEqual(['run-audit']);
  });

  test('form 7 is pinned to the reader, not to the YAML config', () => {
    expect(namesIn('.gaia/audit-ci.yml', 'gate_label: null')).toEqual([]);
    expect(
      namesIn('.gaia/audit-ci.yml', 'DEFAULT_OVERRIDE_LABEL="run-audit"')
    ).toEqual([]);
  });
});

describe('labels/check line numbers', () => {
  test('a continuation reports the line the invocation starts on', () => {
    const text = [
      'run: |',
      '  set -euo pipefail',
      '  issue_url="$(printf %s "$body" | gh issue create \\',
      '    --title "GAIA CI: revert failed; bot stopped" \\',
      '    --label "priority:high" \\',
      '    --label "gaia-ci" \\',
      '    --body-file -)"',
    ].join('\n');

    expect(extractLiterals(SHELL, text)).toEqual([
      {file: SHELL, line: 3, name: 'priority:high'},
      {file: SHELL, line: 3, name: 'gaia-ci'},
    ]);
  });

  test('a separator inside a quoted argument does not end the invocation', () => {
    const text = [
      'pr_url=$(gh pr create \\',
      '  --body "Opened by GAIA CI (GAIA CI - Update Deps)." \\',
      '  --label gaia-ci,needs-human \\',
      '  --head "$BRANCH")',
    ].join('\n');

    expect(namesIn(SHELL, text)).toEqual(['gaia-ci', 'needs-human']);
  });

  test('each single-line invocation reports its own line', () => {
    const text = [
      'gh issue edit "$n" --add-label auto-fixable',
      'gh issue edit "$n" --add-label gaia-triaged',
    ].join('\n');

    expect(extractLiterals(SHELL, text)).toEqual([
      {file: SHELL, line: 1, name: 'auto-fixable'},
      {file: SHELL, line: 2, name: 'gaia-triaged'},
    ]);
  });
});

describe('labels/check gh-context constraints', () => {
  test('constraint 1: a flag outside a gh invocation yields nothing', () => {
    const cases = [
      '--label is required',
      '--label AND --author',
      '--label and --author',
      '--label requires a value',
      '--label a --label b',
    ];

    for (const text of cases) expect(namesIn(SHELL, text)).toEqual([]);
  });

  test('constraint 2: a gh that does not start a command yields nothing', () => {
    expect(
      namesIn(SHELL, '@test "gh issue edit --add-label arms the sentinel" {')
    ).toEqual([]);
    expect(
      namesIn(SHELL, 'echo "error: gh label create failed for $name" >&2')
    ).toEqual([]);
    expect(
      namesIn(SHELL, "  run_hook 'gh issue edit 590 --add-label exits'")
    ).toEqual([]);
  });

  test('constraint 2 still admits a gh after a real separator', () => {
    expect(
      namesIn(SHELL, 'true && gh issue edit 1 --add-label needs-human')
    ).toEqual(['needs-human']);
    expect(
      namesIn(SHELL, 'true; gh issue edit 1 --add-label needs-human')
    ).toEqual(['needs-human']);
    expect(
      namesIn(SHELL, 'url=$(gh issue create --label needs-human)')
    ).toEqual(['needs-human']);
  });

  test('constraint 3: a comment line yields nothing', () => {
    const cases = [
      '# Idempotency: gh issue edit --add-label re-applying an existing label is',
      '// gh issue edit 1 --add-label needs-human',
      ' * gh issue edit 1 --add-label needs-human',
      '> gh issue edit 1 --add-label needs-human',
    ];

    for (const text of cases) expect(namesIn(SHELL, text)).toEqual([]);
  });

  test('a gh verb outside issue, pr, and label does not qualify', () => {
    expect(namesIn(SHELL, 'gh api repos/x/y --label bug')).toEqual([]);
  });
});

describe('labels/check deliberate-negative vocabulary fixtures', () => {
  // The debt-metadata suite feeds its validator invalid vocabulary on purpose.
  // Every one arrives through `run bash "$CHECK"`, not through `gh`, so
  // constraint 2 excludes it without a test-fixture allowlist.
  const invalid = [
    'surface:internal',
    'severity:blocker',
    'difficulty:trivial',
    'handler:agent',
    'fold:optional',
    'fold:maybe',
    'handler:',
    'fold:',
    'severity:',
    'difficulty:',
  ];

  test('every invalid spelling inside a bats invocation yields nothing', () => {
    for (const value of invalid) {
      expect(
        namesIn(
          'suite.bats',
          `  run bash "$CHECK" --pre-file --labels '${value}'`
        )
      ).toEqual([]);
    }
  });

  test('SCAN_EXCLUDED carries no test-fixture allowlist', () => {
    expect(SCAN_EXCLUDED).toEqual([
      'CHANGELOG.md',
      '.gaia/local/',
      'wiki/log.md',
      'wiki/hot.md',
      'wiki/meta/',
      '.gaia/cli/gaia',
      '.gaia/cli/gaia-maintainer',
    ]);
  });
});

describe('labels/check the token rule', () => {
  test('placeholders and shell expansions are skipped, never reported', () => {
    const placeholders = [
      'severity:<tier>',
      'handler:<class>',
      'surface:<side>',
      'difficulty:<grade>',
      '$label',
      '"$n"',
      '{{needs_human_review_label}}',
    ];

    for (const value of placeholders) {
      expect(namesIn(SHELL, `gh issue create --label ${value}`)).toEqual([]);
    }
  });

  test('a placeholder beside a real name loses only the placeholder', () => {
    expect(
      namesIn(
        SHELL,
        'gh issue create --label tech-debt --label severity:<tier>'
      )
    ).toEqual(['tech-debt']);
  });

  test('a quoted name carrying spaces survives the token rule', () => {
    expect(
      namesIn(SHELL, 'gh issue create --label "good first issue" --body x')
    ).toEqual(['good first issue']);
    expect(namesIn(SHELL, "gh issue edit 1 --add-label 'help wanted'")).toEqual(
      ['help wanted']
    );
    expect(
      namesIn(SHELL, 'gh label create "good first issue" --color ededed')
    ).toEqual(['good first issue']);
  });

  test('an unquoted run of words is not one spaced name', () => {
    expect(namesIn(SHELL, 'gh issue create --label good first issue')).toEqual([
      'good',
    ]);
  });

  test('a spaced name inside a YAML flow sequence survives', () => {
    expect(
      namesIn(
        '.github/ISSUE_TEMPLATE/bug_report.yml',
        'labels: [good first issue]'
      )
    ).toEqual(['good first issue']);
    expect(
      namesIn(
        '.github/ISSUE_TEMPLATE/bug_report.yml',
        'labels: [bug, help wanted]'
      )
    ).toEqual(['bug', 'help wanted']);
  });
});

describe('labels/check registry lookup', () => {
  test('a name the registry carries has no problem', () => {
    expect(literalProblem(registry, 'tech-debt')).toBeNull();
  });

  test('a blocked name reaches the registry lookup from a real gh line', () => {
    const [literal] = extractLiterals(
      SHELL,
      'gh issue create --label "good first issue" --body x'
    );

    assert.ok(literal);
    expect(literal.name).toBe('good first issue');
    expect(literalProblem(registry, literal.name)).toContain(
      'blocked in .gaia/labels.json'
    );
  });

  test('an unknown name and a blocked name report differently', () => {
    const unknown = literalProblem(registry, 'priority:high');
    const blocked = literalProblem(registry, 'good first issue');

    expect(unknown).toBe('absent from .gaia/labels.json');
    expect(blocked).toContain('blocked in .gaia/labels.json');
    expect(blocked).toContain('Solicits drive-by contributions');
    expect(blocked).not.toBe(unknown);
  });
});

/**
 * The one block that runs `run`, and the header's "never against the
 * repository" rule survives it: the tree under test is a fixture repository
 * this block builds and deletes, never the live one, so no label migration in
 * flight can red it.
 *
 * What it guards is the discovery step ahead of every extraction test above.
 * Those all hand `extractLiterals` a path and a string directly, so none of
 * them can see a file the scan never opened.
 */
describe('labels/check tracked-file discovery', () => {
  const ABSENT_LABEL = 'absent-from-the-registry';

  const REGISTRY = {
    $schema: '../labels.schema.json',
    description: 'Fixture registry.',
    labels: [
      {
        audience: 'adopter',
        axis: 'type',
        blocked: false,
        color: 'd4c5f9',
        deprecated: false,
        description: 'Fixture entry.',
        features: [],
        managed: true,
        name: 'tech-debt',
        reason: null,
        renamedFrom: [],
      },
    ],
    version: 1,
  };

  let fixture = '';

  const runGitFixture = (...args: string[]): void => {
    execFileSync('git', args, {cwd: fixture, stdio: 'ignore'});
  };

  beforeAll(() => {
    fixture = mkdtempSync(path.join(tmpdir(), 'gaia-labels-quotepath-'));

    runGitFixture('init', '--quiet');
    runGitFixture(...QUOTEPATH_PIN_ARGS);
    runGitFixture('config', 'user.email', 'fixture@example.com');
    runGitFixture('config', 'user.name', 'fixture');

    mkdirSync(path.join(fixture, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(fixture, '.gaia', 'labels.json'),
      `${JSON.stringify(REGISTRY, null, 2)}\n`
    );

    mkdirSync(path.join(fixture, 'wiki'), {recursive: true});
    writeFileSync(
      path.join(fixture, 'wiki', `${NON_ASCII_STEM}.md`),
      `gh issue create --label ${ABSENT_LABEL}\n`
    );

    runGitFixture('add', '--all');
  });

  afterAll(() => {
    rmSync(fixture, {force: true, recursive: true});
  });

  test('the fixture path really is C-quoted, so the assertion below can fail', () => {
    const listed = execFileSync('git', ['ls-files'], {
      cwd: fixture,
      encoding: 'utf8',
    });

    expect(listed).toContain(QUOTED_FIRST_BYTE);
    expect(listed).not.toContain(NON_ASCII_STEM);
  });

  test('a literal in a non-ASCII path is reported, not silently skipped', () => {
    const {code, out} = captureRun(['--repo-root', fixture, '--json']);

    expect(JSON.parse(out)).toEqual({
      findings: [
        {
          file: `wiki/${NON_ASCII_STEM}.md`,
          line: 1,
          name: ABSENT_LABEL,
          why: 'absent from .gaia/labels.json',
        },
      ],
    });
    expect(code).toBe(1);
  });
});
