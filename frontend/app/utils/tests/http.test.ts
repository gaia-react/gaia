import {describe, expect, test} from 'vitest';
import {isLocalRedirect, toHeadersObject} from '../http';

describe('http utils', () => {
  const obj = {fizz: 'buzz', foo: 'bar'};

  test('toHeadersObject should work with Headers', () => {
    expect(toHeadersObject(new Headers(obj))).toEqual(obj);
  });

  test('toHeadersObject should work with object', () => {
    expect(toHeadersObject(new Headers(obj))).toEqual(obj);
  });

  test('toHeadersObject should work with undefined', () => {
    expect(toHeadersObject()).toBeUndefined();
  });

  test('isLocalRedirect accepts same-origin path targets', () => {
    expect(isLocalRedirect('/')).toBe(true);
    expect(isLocalRedirect('/dashboard')).toBe(true);
    expect(isLocalRedirect('/a/b?c=d#e')).toBe(true);
  });

  test('isLocalRedirect rejects off-site and empty targets', () => {
    expect(isLocalRedirect('//evil.com')).toBe(false);
    expect(isLocalRedirect(String.raw`/\evil.com`)).toBe(false);
    expect(isLocalRedirect('https://evil.com')).toBe(false);
    expect(isLocalRedirect('mailto:a@b.com')).toBe(false);
    expect(isLocalRedirect('')).toBe(false);
    expect(isLocalRedirect(null)).toBe(false);
    expect(isLocalRedirect(undefined)).toBe(false);
  });
});
