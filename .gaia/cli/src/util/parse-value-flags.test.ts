/**
 * Strategy: `parseValueFlags` is pure, so every case calls it directly with an
 * in-memory argv. The three consuming command suites cover their own required-
 * field validation; what this suite owns is the argv walk itself.
 */
import {describe, expect, test} from 'vitest';
import {parseValueFlags} from './parse-value-flags.js';
import type {ValueFlagMap} from './parse-value-flags.js';

type Field = 'current' | 'latest';

const VALUE_FLAGS: ValueFlagMap<Field> = {
  '--current': 'current',
  '--latest': 'latest',
};

describe('parseValueFlags', () => {
  test('collects a known --flag <value> pair into state.collected', () => {
    const result = parseValueFlags(['--current', 'a.txt'], VALUE_FLAGS);

    expect(result).toEqual({
      ok: true,
      state: {collected: {current: 'a.txt'}, json: false},
    });
  });

  test('collects several pairs in one walk', () => {
    const result = parseValueFlags(
      ['--current', 'a.txt', '--latest', 'b.txt'],
      VALUE_FLAGS
    );

    expect(result).toEqual({
      ok: true,
      state: {collected: {current: 'a.txt', latest: 'b.txt'}, json: false},
    });
  });

  test('--json sets state.json without consuming the next element', () => {
    const result = parseValueFlags(
      ['--json', '--current', 'a.txt'],
      VALUE_FLAGS
    );

    expect(result).toEqual({
      ok: true,
      state: {collected: {current: 'a.txt'}, json: true},
    });
  });

  test('an empty argv yields empty state', () => {
    const result = parseValueFlags([], VALUE_FLAGS);

    expect(result).toEqual({ok: true, state: {collected: {}, json: false}});
  });

  test('a value that looks like a flag is still taken as the value', () => {
    const result = parseValueFlags(['--current', '--latest'], VALUE_FLAGS);

    expect(result).toEqual({
      ok: true,
      state: {collected: {current: '--latest'}, json: false},
    });
  });

  test('an unknown flag returns its message', () => {
    const result = parseValueFlags(['--nope', 'x'], VALUE_FLAGS);

    expect(result).toEqual({message: 'unknown flag: --nope', ok: false});
  });

  test('a known flag at the end of argv returns the requires-a-value message', () => {
    const result = parseValueFlags(['--current'], VALUE_FLAGS);

    expect(result).toEqual({message: '--current requires a value', ok: false});
  });
});
