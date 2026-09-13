import {describe, expect, test} from 'vitest';
import {decodeToken, encodeToken, TOKEN_PATTERN} from '../token.js';

describe('token', () => {
  test('round-trips a plain coordinate through encode and decode', () => {
    const coordinate = {line: 42, path: 'app/services/foo.ts', pr_number: 1234};
    const token = encodeToken(coordinate);

    expect(TOKEN_PATTERN.test(token)).toBe(true);
    expect(decodeToken(token)).toEqual({ok: true, value: coordinate});
  });

  test('a path carrying a space, a semicolon, and a single quote still produces a token inside the pattern and round-trips', () => {
    const coordinate = {
      line: 7,
      path: "app/services/danger; rm -rf ' file.ts",
      pr_number: 9,
    };
    const token = encodeToken(coordinate);

    expect(TOKEN_PATTERN.test(token)).toBe(true);
    expect(decodeToken(token)).toEqual({ok: true, value: coordinate});
  });

  test('refuses a token outside the character set', () => {
    const decoded = decodeToken('not a token');

    expect(decoded.ok).toBe(false);
  });

  test('refuses a well-formed token whose decoded path is a traversal', () => {
    // base64url of "9:../../etc/passwd:1"
    const forged = Buffer.from('9:../../etc/passwd:1', 'utf8')
      .toString('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    expect(TOKEN_PATTERN.test(forged)).toBe(true);

    const decoded = decodeToken(forged);

    expect(decoded.ok).toBe(false);
  });

  test('refuses a token that does not decode to a three-field shape', () => {
    const forged = Buffer.from('not-three-fields', 'utf8')
      .toString('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    expect(decodeToken(forged).ok).toBe(false);
  });
});
