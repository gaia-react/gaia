import {describe, expect, test} from 'vitest';
import {
  appendSearchParams,
  buildRequestHeaders,
  getUri,
  setPathParams,
} from '../utils';

describe('api utils', () => {
  test('appendSearchParams should return comma array snake_case params', () => {
    const searchParams = {
      animal: ['dog', 'cat', 'fish'],
      helloWorld: 'foobar',
      someNumber: 5,
    };
    expect(
      appendSearchParams('api/test', {searchParams, useSnakeCase: true})
    ).toEqual('api/test?animal=dog,cat,fish&hello_world=foobar&some_number=5');
  });

  test('appendSearchParams should return bracket array and camelCase params', () => {
    const searchParams = {
      animal: ['dog', 'cat', 'fish'],
      helloWorld: 'foobar',
      someNumber: 5,
    };
    expect(
      appendSearchParams('api?test=0', {
        arrayFormat: 'bracket',
        searchParams,
        useSnakeCase: false,
      })
    ).toEqual(
      'api?test=0&animal[]=dog&animal[]=cat&animal[]=fish&helloWorld=foobar&someNumber=5'
    );
  });

  test('setPathParams should replace path params', () => {
    expect(setPathParams('api/:id/test/:name', {id: 1, name: 'foo'})).toBe(
      'api/1/test/foo'
    );

    expect(setPathParams('api/test', {id: 1, name: 'foo'})).toBe('api/test');

    expect(setPathParams('api/test')).toBe('api/test');
  });

  test('getUri should return the uri with no options', () => {
    expect(getUri('api/test')).toBe('api/test');
  });

  test('getUri should return the uri with all options', () => {
    expect(
      getUri('api/test/:id/:action?name=foo', {
        pathParams: {action: 'edit', id: 3},
        searchParams: {
          animal: ['dog', 'cat', 'fish'],
          helloWorld: 'foobar',
          someNumber: 5,
        },
      })
    ).toBe(
      'api/test/3/edit?name=foo&animal=dog,cat,fish&hello_world=foobar&some_number=5'
    );
  });

  test('buildRequestHeaders applies per-request token and language', () => {
    const headers = buildRequestHeaders(undefined, 'abc123', 'ja');

    expect(headers.get('Authorization')).toBe('Bearer abc123');
    expect(headers.get('Accept-Language')).toBe('ja');
  });

  test('buildRequestHeaders preserves caller headers and omits absent values', () => {
    const headers = buildRequestHeaders({'X-Custom': 'keep'});

    expect(headers.get('X-Custom')).toBe('keep');
    expect(headers.get('Authorization')).toBeNull();
    expect(headers.get('Accept-Language')).toBeNull();
  });
});
