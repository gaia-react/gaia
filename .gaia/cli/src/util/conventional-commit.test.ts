import {describe, expect, test} from 'vitest';
import {
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
