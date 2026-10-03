import {describe, expect, test} from 'vitest';
import {
  compact,
  convertCase,
  deepRemoveNil,
  every,
  isNil,
  mapKeys,
  mapValues,
  md5,
  some,
  toCamelCase,
  toSnakeCase,
} from '../object';

const predicate = (value: any) => !!value;

describe('object utils', () => {
  test('every', () => {
    expect(every({}, predicate)).toBe(false);
    expect(every({hello: 'world'}, predicate)).toBe(true);
    expect(every({foo: 0, hello: 'world'}, predicate)).toBe(false);
  });

  test('some', () => {
    expect(some({}, predicate)).toBe(false);
    expect(some({foo: 0, hello: 'world'}, predicate)).toBe(true);
    expect(some({hello: 0}, predicate)).toBe(false);
  });

  test('md5', () => {
    expect(md5({a: 'b'})).toBe('92eff9dda44cb8003ee13990782580ff');
  });

  test('isNil', () => {
    expect(isNil(undefined)).toBe(true);
    expect(isNil(null)).toBe(true);
    expect(isNil(1)).toBe(false);
    expect(isNil('foo')).toBe(false);
    expect(isNil({})).toBe(false);
  });

  test('deepRemoveNil', () => {
    expect(deepRemoveNil(undefined)).toBeUndefined();
    expect(deepRemoveNil(null)).toBeUndefined();
    expect(deepRemoveNil({a: 1, b: undefined, c: 3, d: null})).toEqual({
      a: 1,
      c: 3,
    });
    expect(deepRemoveNil([1, null, undefined, 2, 3, 0])).toEqual([1, 2, 3, 0]);
    expect(
      deepRemoveNil({
        history: [{0: null, 1: undefined, a: [1, 2, null], b: []}],
        hobbies: {
          fishing: 'yes',
          snowboarding: {
            0: 'yes',
            2: null,
          },
        },
        name: 'JohnDoe',
        nestedArray: [[[4]], null],
      })
    ).toEqual({
      history: [{a: [1, 2], b: []}],
      hobbies: {
        fishing: 'yes',
        snowboarding: {
          0: 'yes',
        },
      },
      name: 'JohnDoe',
      nestedArray: [[[4]]],
    });
  });

  test('mapKeys', () => {
    expect(mapKeys({bar: 'baz', foo: 'bar'}, (key) => `${key}1`)).toEqual({
      bar1: 'baz',
      foo1: 'bar',
    });
  });

  test('mapValues', () => {
    expect(
      mapValues({bar: 'baz', foo: 'bar'}, (value) => `${String(value)}1`)
    ).toEqual({
      bar: 'baz1',
      foo: 'bar1',
    });
  });

  test('convertCase', () => {
    expect(convertCase((f) => f, {})).toEqual({});
    const obj = {
      a: [
        {
          a: 1,
          b: [1],
          c: undefined,
          d: null,
          e: true,
          f: [],
        },
      ],
      b: 'John Doe',
      c: [[1, 2, 3, [4, 5, 6], undefined]],
      d: {
        a: {a: 1},
        b: {a: 2},
        c: undefined,
      },
    };
    expect(convertCase((f) => `${f}${f}`, obj)).toEqual({
      aa: [
        {
          aa: 1,
          bb: [1],
          cc: undefined,
          dd: null,
          ee: true,
          ff: [],
        },
      ],
      bb: 'John Doe',
      cc: [[1, 2, 3, [4, 5, 6], undefined]],
      dd: {
        aa: {aa: 1},
        bb: {aa: 2},
        cc: undefined,
      },
    });
  });

  test('toSnakeCase', () => {
    expect(
      toSnakeCase({
        nestedObject: {
          biz: 'baz',
          fizzBuzz: 5,
        },
        someValue: 'foo',
      })
    ).toEqual({
      nested_object: {
        biz: 'baz',
        fizz_buzz: 5,
      },
      some_value: 'foo',
    });
  });

  test('toCamelCase', () => {
    expect(
      toCamelCase({
        nested_object: {
          biz: 'baz',
          fizz_buzz: 5,
        },
        some_value: 'foo',
      })
    ).toEqual({
      nestedObject: {
        biz: 'baz',
        fizzBuzz: 5,
      },
      someValue: 'foo',
    });
  });

  test('compact', () => {
    const obj = {a: 'b', c: '', d: false, e: null, f: []};
    expect(compact(obj)).toEqual({a: 'b'});
    expect(compact(obj, {keepFalsy: true})).toEqual({a: 'b', c: '', d: false});
    expect(compact(obj, {keepEmptyArray: true})).toEqual({a: 'b', f: []});
  });
});
