/**
 * Strategy: `escapeRegExp` is pure, so every case calls it directly. What this
 * suite owns is the **escape set itself**, which is the reason the helper has
 * one home: its call sites build guards whose matching behaviour is decided by
 * which characters get escaped. This suite is what pins the whole set
 * directly; the remaining callers are guards that keep passing their own
 * suites with a wrong set.
 *
 * The set is pinned two ways on purpose. The character-by-character table is
 * the readable statement of intent; the round-trip cases are the ones that
 * would actually catch a wrong escape, because a metacharacter that survives
 * unescaped still produces a *valid* regex, just one that matches the wrong
 * strings.
 */
import {describe, expect, test} from 'vitest';
import {escapeRegExp} from './escape-regexp.js';

// Written as an escaped literal rather than `String.raw`: a template whose
// body ends in a backslash escapes its own closing backtick and will not parse.
const BACKSLASH = '\\';

// Every metacharacter the helper escapes.
const ESCAPED = [
  '.',
  '*',
  '+',
  '?',
  '^',
  '$',
  '{',
  '}',
  '(',
  ')',
  '|',
  '[',
  ']',
  BACKSLASH,
];

// `-` is deliberately absent from the set: it is a metacharacter only inside a
// character class, and no caller interpolates into one. Callers that need
// hyphen adjacency handled bound it with their own token boundaries instead.
const NOT_ESCAPED = [
  '-',
  'a',
  'Z',
  '0',
  '_',
  '/',
  ' ',
  ':',
  '#',
  '@',
  '=',
  ',',
];

describe('escapeRegExp', () => {
  test.each(ESCAPED)('escapes %s', (character) => {
    expect(escapeRegExp(character)).toBe(`${BACKSLASH}${character}`);
  });

  test.each(NOT_ESCAPED)('leaves %s alone', (character) => {
    expect(escapeRegExp(character)).toBe(character);
  });

  test('escapes every occurrence, not just the first', () => {
    expect(escapeRegExp('a.b.c')).toBe(String.raw`a\.b\.c`);
  });

  test('returns the empty string unchanged', () => {
    expect(escapeRegExp('')).toBe('');
  });

  test('the escaped form matches its own input literally', () => {
    const literal = `wiki/A (draft) [v1] {2}.md|*+?^$${BACKSLASH}x`;

    expect(new RegExp(`^${escapeRegExp(literal)}$`, 'u').test(literal)).toBe(
      true
    );
  });

  test('the escaped form does not match a string the metacharacters would', () => {
    // Unescaped, `a.c` matches `abc` and `a+` matches `aaa`. Escaped, neither
    // does: this is the failure a missing metacharacter produces, and it is
    // silent, because the wrong pattern is still a valid regex.
    expect(new RegExp(`^${escapeRegExp('a.c')}$`, 'u').test('abc')).toBe(false);
    expect(new RegExp(`^${escapeRegExp('a+')}$`, 'u').test('aaa')).toBe(false);
  });

  test('an escaped path with a bracket compiles instead of throwing', () => {
    // An unescaped `[` opens a character class the input never closes, so the
    // `new RegExp` call itself throws. A caller compiling a user-supplied path
    // gets a crash rather than a wrong match.
    //
    // The bracket is deliberately unclosed. A balanced `[draft]` compiles as a
    // character class whether or not the brackets were escaped, so this case
    // would stay green with `[` and `]` dropped from the set, asserting
    // nothing while naming the construct it cannot detect.
    expect(() => new RegExp(escapeRegExp('wiki/[draft.md'), 'u')).not.toThrow();
  });
});
