import {describe, expect, test} from 'vitest';
import {
  LocalRedirectSchema,
  resolveLocalRedirect,
  toHeadersObject,
} from '../http';

describe('http utils', () => {
  const plainHeaders = {fizz: 'buzz', foo: 'bar'};

  test('toHeadersObject should work with Headers', () => {
    expect(toHeadersObject(new Headers(plainHeaders))).toEqual(plainHeaders);
  });

  test('toHeadersObject should work with object', () => {
    expect(toHeadersObject(plainHeaders)).toEqual(plainHeaders);
  });

  test('toHeadersObject should work with undefined', () => {
    expect(toHeadersObject()).toBeUndefined();
  });

  test('resolveLocalRedirect returns same-origin path targets', () => {
    expect(resolveLocalRedirect('/')).toBe('/');
    expect(resolveLocalRedirect('/dashboard')).toBe('/dashboard');
    expect(resolveLocalRedirect('/a/b?c=d#e')).toBe('/a/b?c=d#e');
    expect(resolveLocalRedirect('/en/about?x=1#y')).toBe('/en/about?x=1#y');
  });

  test('resolveLocalRedirect returns the resolved path', () => {
    expect(resolveLocalRedirect('/a/../b')).toBe('/b');
    expect(resolveLocalRedirect('/a b')).toBe('/a%20b');
  });

  test('resolveLocalRedirect rejects off-site and empty targets', () => {
    expect(resolveLocalRedirect('//example.com')).toBeUndefined();
    expect(resolveLocalRedirect(String.raw`/\example.com`)).toBeUndefined();
    expect(resolveLocalRedirect('https://example.com')).toBeUndefined();
    expect(resolveLocalRedirect('https://local.invalid/a')).toBeUndefined();
    expect(resolveLocalRedirect('mailto:a@b.com')).toBeUndefined();
    expect(resolveLocalRedirect('a/b')).toBeUndefined();
    expect(resolveLocalRedirect('')).toBeUndefined();
    expect(resolveLocalRedirect(null)).toBeUndefined();
    expect(resolveLocalRedirect(undefined)).toBeUndefined();
  });

  test('resolveLocalRedirect rejects targets the URL parser resolves to another host', () => {
    expect(resolveLocalRedirect('/\t/example.com')).toBeUndefined();
    expect(resolveLocalRedirect('/\n/example.com')).toBeUndefined();
    expect(resolveLocalRedirect('/\r/example.com')).toBeUndefined();
    expect(resolveLocalRedirect('/\t\\example.com')).toBeUndefined();
    expect(resolveLocalRedirect('/\\\t/example.com')).toBeUndefined();
  });

  test('resolveLocalRedirect rejects targets whose resolved path starts with two slashes', () => {
    expect(resolveLocalRedirect('/.//example.com')).toBeUndefined();
    expect(resolveLocalRedirect(String.raw`/./\example.com`)).toBeUndefined();
    expect(resolveLocalRedirect('/a/..//example.com')).toBeUndefined();
  });

  test('resolveLocalRedirect returns undefined for targets the URL parser rejects', () => {
    expect(resolveLocalRedirect('//')).toBeUndefined();
    expect(resolveLocalRedirect('/\\')).toBeUndefined();
    expect(resolveLocalRedirect('//[')).toBeUndefined();
    expect(resolveLocalRedirect('//a b')).toBeUndefined();
  });

  test('LocalRedirectSchema parses to the resolved path or fails', () => {
    expect(LocalRedirectSchema.safeParse('/a/../b').data).toBe('/b');
    expect(LocalRedirectSchema.safeParse('//example.com').success).toBe(false);
    expect(LocalRedirectSchema.safeParse('//').success).toBe(false);
  });
});
