import {describe, expect, test} from 'vitest';
import {
  MAX_LINE,
  normalizeRepoRelativePath,
  parseKey,
  parseKeyLine,
  parseWrappedKeys,
  sameCoordinate,
} from '../key.js';
import type {Validated} from '../key.js';

const refusal = (result: {ok: boolean; reason?: string}): string => {
  if (result.ok) {
    throw new Error('expected a refusal, got a validated value');
  }

  return result.reason ?? '';
};

const validated = <T>(result: Validated<T>): T => {
  if (!result.ok) {
    throw new Error(
      `expected a validated value, got a refusal: ${result.reason}`
    );
  }

  return result.value;
};

const wrapped = (inner: string): string => `<!-- gaia-debt-key: ${inner} -->`;

describe('normalizeRepoRelativePath, refusals', () => {
  test('refuses an absolute path, naming the absolute prefix', () => {
    expect(refusal(normalizeRepoRelativePath('/etc/passwd'))).toContain(
      'absolute prefix'
    );
    expect(
      refusal(normalizeRepoRelativePath(String.raw`C:\Windows`))
    ).toContain('absolute prefix');
    expect(
      refusal(normalizeRepoRelativePath(String.raw`\\host\share`))
    ).toContain('absolute prefix');
  });

  test('refuses a traversal path, before and after normalization', () => {
    expect(
      refusal(normalizeRepoRelativePath('app/../../etc/passwd'))
    ).toContain('traversal segment');
    expect(refusal(normalizeRepoRelativePath('app/./../../x'))).toContain(
      'traversal segment'
    );
  });

  test('refuses a leading-dash path with its own reason', () => {
    expect(refusal(normalizeRepoRelativePath('--upload-pack=x'))).toContain(
      'leading dash'
    );
  });

  test('refuses an embedded control character, naming which one', () => {
    expect(refusal(normalizeRepoRelativePath('app/foo\nbar.ts'))).toContain(
      'newline'
    );
    expect(refusal(normalizeRepoRelativePath('app/foo\rbar.ts'))).toContain(
      'carriage return'
    );
    expect(refusal(normalizeRepoRelativePath('app/foo\0bar.ts'))).toContain(
      'NUL'
    );
  });

  test('refuses an empty path and one that normalizes to empty', () => {
    expect(refusal(normalizeRepoRelativePath(''))).toContain('empty');
    expect(refusal(normalizeRepoRelativePath('./'))).toContain(
      'normalizes to empty'
    );
  });
});

describe('normalizeRepoRelativePath, accepted forms', () => {
  test('collapses dot segments, repeated separators, and a trailing separator', () => {
    expect(normalizeRepoRelativePath('app/./services//foo.ts')).toStrictEqual({
      ok: true,
      value: 'app/services/foo.ts',
    });
    expect(normalizeRepoRelativePath('app/services/')).toStrictEqual({
      ok: true,
      value: 'app/services',
    });
    expect(normalizeRepoRelativePath('.gaia/scripts/w.sh')).toStrictEqual({
      ok: true,
      value: '.gaia/scripts/w.sh',
    });
  });

  test('accepts a path carrying a space', () => {
    expect(normalizeRepoRelativePath('app/my file.ts')).toStrictEqual({
      ok: true,
      value: 'app/my file.ts',
    });
  });
});

describe('parseKeyLine', () => {
  test('refuses a signed line', () => {
    expect(refusal(parseKeyLine('-1'))).toContain('sign');
    expect(refusal(parseKeyLine('+5'))).toContain('sign');
  });

  test('refuses a line that is not a bare digit run', () => {
    expect(refusal(parseKeyLine('1e3'))).toContain('bare digit run');
    expect(refusal(parseKeyLine('4 '))).toContain('bare digit run');
  });

  test('refuses a leading zero', () => {
    expect(refusal(parseKeyLine('042'))).toContain('leading zero');
  });

  test('refuses a line below 1 and one above MAX_LINE', () => {
    expect(refusal(parseKeyLine('0'))).toContain('below 1');
    expect(refusal(parseKeyLine(String(MAX_LINE + 1)))).toContain(
      'exceeds the maximum'
    );
  });

  test('accepts the bounds themselves', () => {
    expect(parseKeyLine('1')).toStrictEqual({ok: true, value: 1});
    expect(parseKeyLine(String(MAX_LINE))).toStrictEqual({
      ok: true,
      value: MAX_LINE,
    });
  });
});

describe('parseKey, the gate grammar', () => {
  test('parses a valid key into a normalized coordinate', () => {
    expect(
      parseKey('v1 class=a/one path=app/./one.ts line=42', 'gate')
    ).toStrictEqual({
      ok: true,
      value: {class: 'a/one', line: 42, path: 'app/one.ts', version: 'v1'},
    });
  });

  test('refuses a key missing the v1 version token', () => {
    expect(
      refusal(parseKey('class=a/one path=app/one.ts line=42', 'gate'))
    ).toContain('v1 version token');
  });

  test('routes a field refusal through with its own reason', () => {
    expect(
      refusal(parseKey('v1 class=a/one path=/etc/passwd line=42', 'gate'))
    ).toContain('absolute prefix');
    expect(
      refusal(parseKey('v1 class=a/one path=app/one.ts line=0', 'gate'))
    ).toContain('below 1');
    expect(
      refusal(parseKey('v1 class=a/one path=app/one\nx.ts line=42', 'gate'))
    ).toContain('newline');
  });
});

describe('sameCoordinate', () => {
  test('compares on the normalized path form', () => {
    expect(
      sameCoordinate(
        {line: 42, path: 'app/./services//foo.ts'},
        {line: 42, path: 'app/services/foo.ts'}
      )
    ).toBe(true);
  });

  test('separates two lines that differ', () => {
    expect(
      sameCoordinate(
        {line: 4, path: 'app/services/foo.ts'},
        {line: 42, path: 'app/services/foo.ts'}
      )
    ).toBe(false);
  });

  test('ignores class: two keys differing only in class share one coordinate', () => {
    const left = validated(
      parseKey('v1 class=a/one path=app/one.ts line=7', 'gate')
    );
    const right = validated(
      parseKey('v1 class=z/other path=app/one.ts line=7', 'gate')
    );

    expect(left.class).not.toBe(right.class);
    expect(sameCoordinate(left, right)).toBe(true);
  });

  test('treats an unvalidatable path as no match rather than a throw', () => {
    expect(
      sameCoordinate(
        {line: 1, path: '/etc/passwd'},
        {line: 1, path: '/etc/passwd'}
      )
    ).toBe(false);
  });
});

describe('parseWrappedKeys, the filer grammar', () => {
  test('returns a key carrying no v1 token, which the gate grammar refuses', () => {
    const body = `Some issue prose.\n${wrapped('class=a/one path=app/one.ts line=5')}\n`;

    expect(parseWrappedKeys(body)).toStrictEqual([
      {line: 5, path: 'app/one.ts'},
    ]);
    expect(parseKey('class=a/one path=app/one.ts line=5', 'gate').ok).toBe(
      false
    );
  });

  test('parseWrappedKeys and parseKey agree on a spaced-path key', () => {
    const inner = 'v1 class=a/one path=app/my file.ts line=5';

    expect(parseWrappedKeys(wrapped(inner))).toStrictEqual([
      {line: 5, path: 'app/my file.ts'},
    ]);
    expect(validated(parseKey(inner, 'gate'))).toMatchObject({
      line: 5,
      path: 'app/my file.ts',
    });
  });

  test('returns every key in body order and drops one it cannot validate', () => {
    const body = [
      wrapped('v1 class=a/one path=app/one.ts line=11'),
      wrapped('v1 class=a/abs path=/etc/passwd line=12'),
      wrapped('v1 class=a/up path=app/../../x line=13'),
      wrapped('v1 class=a/two path=app/two.ts line=22'),
    ].join('\n');

    expect(parseWrappedKeys(body)).toStrictEqual([
      {line: 11, path: 'app/one.ts'},
      {line: 22, path: 'app/two.ts'},
    ]);
  });

  test('drops a key whose line is not a digit run', () => {
    expect(
      parseWrappedKeys(wrapped('v1 class=a/one path=app/one.ts line=x'))
    ).toStrictEqual([]);
  });

  test('returns nothing for issue prose that merely mentions path=', () => {
    expect(
      parseWrappedKeys('This issue is about path=app/one.ts line=5 in prose.')
    ).toStrictEqual([]);
    expect(
      parseWrappedKeys('gaia-debt-key: path=app/one.ts line=5')
    ).toStrictEqual([]);
  });
});
