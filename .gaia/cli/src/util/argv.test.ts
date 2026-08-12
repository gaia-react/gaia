/**
 * Strategy: all three primitives are pure, so every case calls them directly.
 * The divergence block is the point of the suite: `takeValue` and
 * `takeNonFlagValue` disagree on exactly one input shape, and both answers are
 * shipped, so a change that collapses them into one semantic fails here rather
 * than silently at whichever call sites were relaxed or tightened.
 */
import {describe, expect, test} from 'vitest';
import {lookupOwn, takeNonFlagValue, takeValue} from './argv.js';

const PROTOTYPE_KEYS = [
  '__proto__',
  'constructor',
  'hasOwnProperty',
  'isPrototypeOf',
  'propertyIsEnumerable',
  'toLocaleString',
  'toString',
  'valueOf',
];

const TABLE: Readonly<Partial<Record<string, string>>> = {
  '--out': 'out',
  build: 'build',
};

describe('lookupOwn', () => {
  test('returns the value for an own key', () => {
    expect(lookupOwn(TABLE, 'build')).toBe('build');
  });

  test('returns undefined for an absent key', () => {
    expect(lookupOwn(TABLE, 'bogus')).toBeUndefined();
  });

  test.each(PROTOTYPE_KEYS)('returns undefined for %s', (key) => {
    expect(lookupOwn(TABLE, key)).toBeUndefined();
  });

  test.each(PROTOTYPE_KEYS)('a bare index would resolve %s', (key) => {
    const bare: Record<string, unknown> = {...TABLE};

    expect(bare[key]).toBeDefined();
  });

  test('an own key shadowing a prototype key still resolves', () => {
    expect(lookupOwn({toString: 'real'}, 'toString')).toBe('real');
  });
});

describe('takeValue', () => {
  test('reads the element at index', () => {
    expect(takeValue(['--out', 'file.txt'], 1, '--out')).toEqual({
      ok: true,
      value: 'file.txt',
    });
  });

  test('reports a missing value past the end of argv', () => {
    expect(takeValue(['--out'], 1, '--out')).toEqual({
      message: '--out requires a value',
      ok: false,
    });
  });

  test('reads an empty string as a value', () => {
    expect(takeValue(['--out', ''], 1, '--out')).toEqual({ok: true, value: ''});
  });
});

describe('takeNonFlagValue', () => {
  test('reads the element at index', () => {
    expect(takeNonFlagValue(['--out', 'file.txt'], 1, '--out')).toEqual({
      ok: true,
      value: 'file.txt',
    });
  });

  test('reports a missing value past the end of argv', () => {
    expect(takeNonFlagValue(['--out'], 1, '--out')).toEqual({
      message: '--out requires a value',
      ok: false,
    });
  });

  test('reads a single-dash element as a value', () => {
    expect(takeNonFlagValue(['--out', '-x'], 1, '--out')).toEqual({
      ok: true,
      value: '-x',
    });
  });
});

describe('the two readers diverge on a --flag-shaped value', () => {
  test('takeValue consumes the following flag as the value', () => {
    expect(takeValue(['--out', '--json'], 1, '--out')).toEqual({
      ok: true,
      value: '--json',
    });
  });

  test('takeNonFlagValue reports a missing value instead', () => {
    expect(takeNonFlagValue(['--out', '--json'], 1, '--out')).toEqual({
      message: '--out requires a value',
      ok: false,
    });
  });
});
