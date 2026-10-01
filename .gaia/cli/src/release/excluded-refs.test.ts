import {describe, expect, test} from 'vitest';
import {
  compileExcludedRefMatcher,
  deriveExcludedRefTokens,
} from './excluded-refs.js';
import type {ExcludedRefInputs} from './excluded-refs.js';

const TRACKED = [
  '.claude/agents/code-audit-maintainer-node.md',
  '.claude/commands/gaia-release.md',
  '.claude/skills/release-notes/SKILL.md',
  '.gaia/cli/gaia-maintainer',
  '.gaia/cli/src/wiki/chain.ts',
  '.gaia/cli/src/wiki/index.ts',
  '.gaia/cli/test-fixtures/cost.jsonl',
  '.gaia/scripts/lint-hook-jq-availability.sh',
  '.gaia/tests/run-all.sh',
  '.github/CODEOWNERS',
  '.github/workflows/release.yml',
  'README.md',
];

const baseInputs = (
  overrides: Partial<ExcludedRefInputs> = {}
): ExcludedRefInputs => ({
  excludeLines: [
    '.claude/agents/code-audit-maintainer-node.md',
    '.claude/commands/gaia-release.md',
    '.claude/skills/release-notes',
    '.gaia/cli/gaia-maintainer',
    '.gaia/cli/src',
    '.gaia/cli/test-fixtures',
    '.gaia/scripts/lint-hook-jq-availability.sh',
    '.gaia/tests',
    '.github/CODEOWNERS',
    '.github/workflows/release.yml',
    '.serena',
    'README.md',
  ],
  isExecutable: (relativePath) => relativePath === '.gaia/cli/gaia-maintainer',
  optOut: [],
  shippedBasenames: new Set(['index.ts', 'SKILL.md']),
  tracked: TRACKED,
  ...overrides,
});

describe('deriveExcludedRefTokens', () => {
  test('keeps tracked excluded paths and drops untracked, root-level, and workflow entries', () => {
    const {paths} = deriveExcludedRefTokens(baseInputs());

    expect(paths).toEqual(
      expect.arrayContaining([
        '.gaia/cli/src',
        '.gaia/tests',
        '.gaia/scripts/lint-hook-jq-availability.sh',
      ])
    );
    // Untracked local state, a root governance file, and a workflow the
    // excluded-workflow-ref check owns.
    expect(paths).not.toContain('.serena');
    expect(paths).not.toContain('README.md');
    expect(paths).not.toContain('.github/workflows/release.yml');
  });

  test('derives slash commands from excluded commands and skills', () => {
    expect(deriveExcludedRefTokens(baseInputs()).commands).toEqual([
      'gaia-release',
      'release-notes',
    ]);
  });

  test('derives agent names from excluded agent files', () => {
    expect(deriveExcludedRefTokens(baseInputs()).agents).toEqual([
      'code-audit-maintainer-node',
    ]);
  });

  test('derives basenames only for unshared code files and executables', () => {
    const {basenames} = deriveExcludedRefTokens(baseInputs());

    expect(basenames).toEqual(
      expect.arrayContaining([
        'chain.ts',
        'gaia-maintainer',
        'lint-hook-jq-availability.sh',
        'run-all.sh',
      ])
    );
    // A shipped file shares it, and a data fixture adopters also generate.
    expect(basenames).not.toContain('index.ts');
    expect(basenames).not.toContain('cost.jsonl');
  });

  test('subtracts opt-out tokens by exact equality and reports the unused ones', () => {
    const tokens = deriveExcludedRefTokens(
      baseInputs({optOut: ['.github/CODEOWNERS', '.github/no-such-path']})
    );

    expect(tokens.paths).not.toContain('.github/CODEOWNERS');
    expect(tokens.unusedOptOut).toEqual(['.github/no-such-path']);
  });
});

describe('compileExcludedRefMatcher', () => {
  const matcher = compileExcludedRefMatcher(
    deriveExcludedRefTokens(baseInputs())
  );

  test.each<[string, string, string[]]>([
    ['a path prefix', 'see `.gaia/tests/run-all.sh` for it', ['.gaia/tests']],
    ['a bare directory', 'find .gaia/tests -name x', ['.gaia/tests']],
    ['a dot-slash path', 'run ./.gaia/cli/src/x.ts', ['.gaia/cli/src']],
    ['a slash command', 'Before `/gaia-release` runs', ['/gaia-release']],
    [
      'an agent name',
      'spawn code-audit-maintainer-node now',
      ['code-audit-maintainer-node'],
    ],
    [
      'an excluded file path',
      'the `.gaia/scripts/lint-hook-jq-availability.sh` lint',
      ['.gaia/scripts/lint-hook-jq-availability.sh'],
    ],
  ])('flags %s', (_label, line, expected) => {
    expect(matcher(line, {markdown: false})).toEqual(expected);
  });

  test.each<[string, string]>([
    ['a longer path sharing the prefix', '.gaia/testsuite/foo.sh'],
    ['a path nested under another tree', 'vendor/.gaia/tests/x'],
    ['a command inside a path', '.claude/skills/x/gaia-release-notes'],
    ['a command as a URL segment', 'github.com/org/gaia-release'],
    ['a longer command', 'run /gaia-releases'],
  ])('does not flag %s', (_label, line) => {
    expect(matcher(line, {markdown: true})).toEqual([]);
  });

  test('matches basenames in Markdown only', () => {
    const line = 'the record comes from `chain.ts` and `gaia-maintainer`';

    expect(matcher(line, {markdown: true})).toEqual([
      'chain.ts',
      'gaia-maintainer',
    ]);
    expect(matcher(line, {markdown: false})).toEqual([]);
  });

  test('reports a full path once, not again as its basename', () => {
    expect(
      matcher('see .gaia/scripts/lint-hook-jq-availability.sh', {
        markdown: true,
      })
    ).toEqual(['.gaia/scripts/lint-hook-jq-availability.sh']);
  });

  test('matches nothing when nothing is derived', () => {
    const empty = compileExcludedRefMatcher(
      deriveExcludedRefTokens(baseInputs({excludeLines: []}))
    );

    expect(empty('.gaia/tests and /gaia-release', {markdown: true})).toEqual(
      []
    );
  });
});
