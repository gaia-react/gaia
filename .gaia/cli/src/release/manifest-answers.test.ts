import {describe, expect, test} from 'vitest';
/**
 * Unit tests for the pure answer machinery behind the `release manifest`
 * refusal gate.
 *
 * Every case runs against the inline fixture below, never against the live
 * `.gaia/release-exclude`. The real boundary file is edited whenever a
 * maintainer withholds something, so a test asserting "category 1's last line
 * is X" or "the file has twelve categories" would be a test of today's
 * distribution boundary rather than of this module.
 */
import {
  applyWithholds,
  parseExcludeCategories,
  validateAnswers,
} from './manifest-answers.js';
import type {
  AnswerErrorCode,
  AnswerSet,
  WithholdAnswer,
} from './manifest-answers.js';

const EXCLUDE_FIXTURE = [
  '# Paths excluded from the distribution tarball.',
  '# One path or glob per line; `#` comments are honored.',
  '',
  '# --- 1. Maintainer-only Claude surface ---',
  '# Commands only the maintainer ever runs.',
  '.claude/commands/gaia-release.md',
  '.gaia/statusline/preferred-base.sh',
  '',
  '# --- 2. Maintainer-only wiki content ---',
  '# Internal vault administration.',
  'wiki/entities',
  '',
  '# --- 3. Test harnesses and audit reports ---',
  '.gaia/tests',
  '',
].join('\n');

const withhold = (
  path: string,
  overrides: Partial<WithholdAnswer> = {}
): WithholdAnswer => ({
  category: 1,
  path,
  reason: 'maintainer-only',
  ...overrides,
});

const answers = (overrides: Partial<AnswerSet> = {}): AnswerSet => ({
  allowUndecided: false,
  ships: [],
  withholds: [],
  ...overrides,
});

const codesOf = (
  errors: readonly {code: AnswerErrorCode}[]
): AnswerErrorCode[] => errors.map((error) => error.code);

const CATEGORIES = parseExcludeCategories(EXCLUDE_FIXTURE);

describe('parseExcludeCategories', () => {
  test('finds every numbered header in file order with 0-based line indices', () => {
    expect(CATEGORIES).toEqual([
      {
        headerLineIndex: 3,
        number: 1,
        title: 'Maintainer-only Claude surface',
      },
      {headerLineIndex: 8, number: 2, title: 'Maintainer-only wiki content'},
      {
        headerLineIndex: 12,
        number: 3,
        title: 'Test harnesses and audit reports',
      },
    ]);
  });

  test('ignores comments and path lines that are not numbered headers', () => {
    expect(parseExcludeCategories('# just a comment\nwiki/entities\n')).toEqual(
      []
    );
  });

  test('returns an empty list for an empty body', () => {
    expect(parseExcludeCategories('')).toEqual([]);
  });
});

describe('applyWithholds', () => {
  test('inserts the reason comment and the verbatim path at column zero', () => {
    const result = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
    ]);
    const lines = result.split('\n');
    const pathIndex = lines.indexOf('.gaia/statusline/example.sh');

    expect(pathIndex).toBeGreaterThan(-1);
    expect(lines[pathIndex - 1]).toBe('# maintainer-only');
  });

  test('inserts below the chosen header and above the next one', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('wiki/meta', {category: 2, reason: 'internal'}),
    ]).split('\n');
    const pathIndex = lines.indexOf('wiki/meta');

    expect(pathIndex).toBeGreaterThan(
      lines.findIndex((line) => line.startsWith('# --- 2.'))
    );
    expect(pathIndex).toBeLessThan(
      lines.findIndex((line) => line.startsWith('# --- 3.'))
    );
  });

  test('inserts after the last non-blank line, keeping the blank separator', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
    ]).split('\n');
    const pathIndex = lines.indexOf('.gaia/statusline/example.sh');

    // The category's own last path line, then the two new lines, then the
    // blank line that separates the block from the next header.
    expect(lines[pathIndex - 2]).toBe('.gaia/statusline/preferred-base.sh');
    expect(lines[pathIndex + 1]).toBe('');
    expect(lines[pathIndex + 2]).toBe(
      '# --- 2. Maintainer-only wiki content ---'
    );
  });

  test('appends a second withhold into the same category below the first', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/first.sh', {reason: 'first'}),
      withhold('.gaia/statusline/second.sh', {reason: 'second'}),
    ]).split('\n');
    const firstIndex = lines.indexOf('.gaia/statusline/first.sh');
    const secondIndex = lines.indexOf('.gaia/statusline/second.sh');

    expect(firstIndex).toBeGreaterThan(-1);
    expect(secondIndex).toBe(firstIndex + 2);
    expect(lines[secondIndex - 1]).toBe('# second');
    expect(lines[secondIndex + 1]).toBe('');
  });

  test('routes withholds to their own categories', () => {
    const lines = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/statusline/example.sh'),
      withhold('wiki/meta', {category: 2, reason: 'internal'}),
      withhold('.gaia/probe', {category: 3, reason: 'harness'}),
    ]).split('\n');
    const header2 = lines.findIndex((line) => line.startsWith('# --- 2.'));
    const header3 = lines.findIndex((line) => line.startsWith('# --- 3.'));

    expect(lines.indexOf('.gaia/statusline/example.sh')).toBeLessThan(header2);
    expect(lines.indexOf('wiki/meta')).toBeGreaterThan(header2);
    expect(lines.indexOf('wiki/meta')).toBeLessThan(header3);
    expect(lines.indexOf('.gaia/probe')).toBeGreaterThan(header3);
  });

  test('appends into the last category, preserving the trailing newline', () => {
    const result = applyWithholds(EXCLUDE_FIXTURE, [
      withhold('.gaia/probe', {category: 3, reason: 'harness'}),
    ]);

    expect(result.endsWith('# harness\n.gaia/probe\n')).toBe(true);
  });

  test('leaves the text untouched when there is nothing to withhold', () => {
    expect(applyWithholds(EXCLUDE_FIXTURE, [])).toBe(EXCLUDE_FIXTURE);
  });
});

describe('validateAnswers', () => {
  const missing = ['app/new.ts', 'docs/guide.md'];

  test('returns no errors for an exactly-covering answer set', () => {
    const errors = validateAnswers(
      answers({
        ships: ['app/new.ts'],
        withholds: [withhold('docs/guide.md')],
      }),
      missing,
      CATEGORIES
    );

    expect(errors).toEqual([]);
  });

  test('unanswered_paths names every unanswered file', () => {
    const errors = validateAnswers(answers(), missing, CATEGORIES);

    expect(codesOf(errors)).toEqual(['unanswered_paths']);
    expect(errors[0]?.paths).toEqual(['app/new.ts', 'docs/guide.md']);
  });

  test('--allow-undecided waives exact cover and nothing else', () => {
    expect(
      validateAnswers(answers({allowUndecided: true}), missing, CATEGORIES)
    ).toEqual([]);

    // Membership still applies to whatever answers were given.
    const errors = validateAnswers(
      answers({allowUndecided: true, ships: ['app/ghost.ts']}),
      missing,
      CATEGORIES
    );
    expect(codesOf(errors)).toEqual(['answer_not_missing']);
  });

  test('answer_not_missing rejects a bare directory standing in for its subtree', () => {
    const errors = validateAnswers(
      answers({
        ships: ['app/new.ts'],
        withholds: [withhold('docs', {reason: 'internal'})],
      }),
      missing,
      CATEGORIES
    );

    // The directory carries no metacharacter; membership is what rejects it.
    expect(codesOf(errors)).toContain('answer_not_missing');
    expect(codesOf(errors)).not.toContain('withhold_metacharacter');
    expect(errors[0]?.paths).toEqual(['docs']);
  });

  test('answer_not_missing collects every offending path, not just the first', () => {
    const errors = validateAnswers(
      answers({ships: ['app/typo.ts', 'docs/typo.md']}),
      missing,
      CATEGORIES
    );

    expect(errors[0]?.paths).toEqual(['app/typo.ts', 'docs/typo.md']);
  });

  test('duplicate_answer flags a path answered twice, and one answered both ways', () => {
    const twice = validateAnswers(
      answers({
        allowUndecided: true,
        ships: ['app/new.ts', 'app/new.ts'],
      }),
      missing,
      CATEGORIES
    );
    expect(codesOf(twice)).toEqual(['duplicate_answer']);
    expect(twice[0]?.paths).toEqual(['app/new.ts']);

    const bothWays = validateAnswers(
      answers({
        allowUndecided: true,
        ships: ['app/new.ts'],
        withholds: [withhold('app/new.ts')],
      }),
      missing,
      CATEGORIES
    );
    expect(codesOf(bothWays)).toEqual(['duplicate_answer']);
  });

  test('withhold_metacharacter rejects a bracketed filename that IS a member', () => {
    const errors = validateAnswers(
      answers({
        allowUndecided: true,
        withholds: [withhold('docs/notes[1].md')],
      }),
      ['docs/notes[1].md'],
      CATEGORIES
    );

    expect(codesOf(errors)).toEqual(['withhold_metacharacter']);
  });

  test.each([
    ['a star', 'docs/*.md'],
    ['a brace', 'docs/{a,b}.md'],
    ['an anchor', '^docs/a.md'],
    ['a pipe', 'docs/a|b.md'],
    ['a backslash', String.raw`docs\a.md`],
    ['a leading slash', '/docs/a.md'],
    ['a trailing slash', 'docs/a/'],
    ['a leading hash', '#docs/a.md'],
    ['embedded whitespace', 'docs/a b.md'],
    ['an empty value', ''],
  ])('withhold_metacharacter rejects %s', (_label, badPath) => {
    const errors = validateAnswers(
      answers({allowUndecided: true, withholds: [withhold(badPath)]}),
      [badPath],
      CATEGORIES
    );

    expect(codesOf(errors)).toContain('withhold_metacharacter');
  });

  test.each([
    ['a dot and a plus', 'app/routes/_public+/home.tsx'],
    ['a tilde and an at', 'docs/~notes@2.md'],
    ['a comma and an equals', 'docs/a,b=c.md'],
  ])('allows %s in a withhold path', (_label, goodPath) => {
    const errors = validateAnswers(
      answers({allowUndecided: true, withholds: [withhold(goodPath)]}),
      [goodPath],
      CATEGORIES
    );

    expect(errors).toEqual([]);
  });

  test.each([
    ['a newline', 'internal\nwiki/decisions'],
    ['a carriage return', 'internal\rwiki/decisions'],
    ['an empty reason', ''],
    ['a whitespace-only reason', ' '.repeat(3)],
  ])('withhold_reason_invalid rejects %s', (_label, reason) => {
    const errors = validateAnswers(
      answers({
        allowUndecided: true,
        withholds: [withhold('app/new.ts', {reason})],
      }),
      missing,
      CATEGORIES
    );

    expect(codesOf(errors)).toEqual(['withhold_reason_invalid']);
  });

  test('unknown_category rejects a category no header declares', () => {
    const errors = validateAnswers(
      answers({
        allowUndecided: true,
        withholds: [withhold('app/new.ts', {category: 99})],
      }),
      missing,
      CATEGORIES
    );

    expect(codesOf(errors)).toEqual(['unknown_category']);
    expect(errors[0]?.paths).toEqual(['app/new.ts']);
  });

  test('reports every error class in one pass', () => {
    const errors = validateAnswers(
      answers({
        ships: ['app/ghost.ts'],
        withholds: [
          withhold('docs/*.md', {category: 99, reason: 'bad\nreason'}),
        ],
      }),
      missing,
      CATEGORIES
    );

    expect(codesOf(errors)).toEqual([
      'answer_not_missing',
      'withhold_metacharacter',
      'withhold_reason_invalid',
      'unknown_category',
      'unanswered_paths',
    ]);
  });
});
