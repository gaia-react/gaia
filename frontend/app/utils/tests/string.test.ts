import {describe, expect, test} from 'vitest';
import {toInitialCap, toTitleCase} from '../string';

describe('string utils', () => {
  test('toInitialCap', () => {
    expect(toInitialCap('foo bar')).toBe('Foo bar');
    expect(toInitialCap('Foo bar')).toBe('Foo bar');
    expect(toInitialCap('-foo bar')).toBe('-foo bar');
    expect(toInitialCap('')).toBe('');
    expect(toInitialCap()).toBeUndefined();
  });

  test('toTitleCase', () => {
    expect(toTitleCase('foo_bar')).toBe('Foo Bar');
    expect(toTitleCase('foobar')).toBe('Foobar');
    expect(toTitleCase('foo-bar-baz-biz', '-')).toBe('Foo Bar Baz Biz');
  });
});
