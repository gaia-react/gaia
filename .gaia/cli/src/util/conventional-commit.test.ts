import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import {
  COMMIT_TYPES,
  isCommitType,
  parseConventionalCommitHeader,
} from './conventional-commit.js';

describe('parseConventionalCommitHeader', () => {
  test('parses a bare type', () => {
    expect(parseConventionalCommitHeader('fix: repair the thing')).toEqual({
      breaking: false,
      rest: 'repair the thing',
      scope: undefined,
      type: 'fix',
    });
  });

  test('captures the scope by name', () => {
    expect(
      parseConventionalCommitHeader('fix(hooks): repair the thing')
    ).toEqual({
      breaking: false,
      rest: 'repair the thing',
      scope: 'hooks',
      type: 'fix',
    });
  });

  // The drift that motivated the extraction: `bump.ts` read the bang on any
  // type, `changelog.ts` matched it without capturing, and only
  // `commit-classify.ts` named the scope. All three now read this one answer.
  test.each([
    ['feat!: drop it', {breaking: true, scope: undefined, type: 'feat'}],
    ['chore(cli)!: drop it', {breaking: true, scope: 'cli', type: 'chore'}],
    [
      'refactor(a/b)!: move it',
      {breaking: true, scope: 'a/b', type: 'refactor'},
    ],
  ])('%s exposes scope and bang together', (subject, expected) => {
    const header = parseConventionalCommitHeader(subject);
    expect(header?.breaking).toBe(expected.breaking);
    expect(header?.scope).toBe(expected.scope);
    expect(header?.type).toBe(expected.type);
  });

  test('an empty scope is captured as an empty string, not undefined', () => {
    expect(parseConventionalCommitHeader('fix(): thing')?.scope).toBe('');
  });

  test('rest is the message with surrounding whitespace stripped', () => {
    expect(parseConventionalCommitHeader('feat(api):   spaced   ')?.rest).toBe(
      'spaced'
    );
  });

  test('rest is empty when the subject is only a header', () => {
    expect(parseConventionalCommitHeader('chore:')?.rest).toBe('');
  });

  test('leading whitespace on the subject does not defeat the match', () => {
    expect(parseConventionalCommitHeader('  fix: thing')?.type).toBe('fix');
  });

  test.each([
    'Harden the Code Audit Team merge gate (#793)',
    'Merge pull request #42 from feature/foo',
    'FIX: shouting is not the grammar',
    'fix2: digits are not part of the type',
    'fix (hooks): a space before the scope breaks it',
    '',
  ])('%s is not a conventional-commit header', (subject) => {
    expect(parseConventionalCommitHeader(subject)).toBeUndefined();
  });
});

describe('COMMIT_TYPES', () => {
  // Only the negative case is worth asserting. That `isCommitType` accepts
  // every member of the list it is built from restates the implementation, and
  // freezing the list here would catch nothing: each consumer's
  // `Record<CommitType, ...>` already fails to compile on both an added type
  // (missing key) and a removed one (excess key).
  test('isCommitType rejects a type nobody declared', () => {
    expect(isCommitType('spike')).toBe(false);
  });
});

type SharedTypeFile = {legacyTypes: string[]; types: string[]};

/**
 * Throw unless the CLI's literal tuple names exactly the shared file's `types`
 * plus `legacyTypes`. A parameterized helper so a unit test can feed it a
 * mismatched pair and watch it refuse.
 */
const assertTypesAgree = (
  cliTypes: readonly string[],
  shared: SharedTypeFile
): void => {
  const expected = [...shared.types, ...shared.legacyTypes];
  const expectedSet = new Set(expected);
  const agrees =
    cliTypes.length === expected.length &&
    cliTypes.every((type) => expectedSet.has(type));

  if (!agrees) {
    throw new Error(
      `COMMIT_TYPES [${cliTypes.join(', ')}] disagrees with .gaia/conventional-commits.json [${expected.join(', ')}]`
    );
  }
};

describe('COMMIT_TYPES lockstep with .gaia/conventional-commits.json', () => {
  const shared = JSON.parse(
    readFileSync(
      new URL('../../../conventional-commits.json', import.meta.url),
      'utf8'
    )
  ) as SharedTypeFile;

  test('the tuple equals types plus legacyTypes', () => {
    expect(() => assertTypesAgree(COMMIT_TYPES, shared)).not.toThrow();
  });

  test('debt stays parseable but is not a type for new commits', () => {
    expect(isCommitType('debt')).toBe(true);
    expect(shared.types).not.toContain('debt');
  });

  test('every type for new commits is a declared CommitType', () => {
    for (const type of shared.types) expect(isCommitType(type)).toBe(true);
  });

  test('the helper refuses a type the tuple lacks', () => {
    expect(() =>
      assertTypesAgree(COMMIT_TYPES, {
        ...shared,
        types: [...shared.types, 'zzz'],
      })
    ).toThrow(/disagrees/u);
  });

  test('the helper refuses a type the file lacks', () => {
    expect(() => assertTypesAgree([...COMMIT_TYPES, 'zzz'], shared)).toThrow(
      /disagrees/u
    );
  });
});
