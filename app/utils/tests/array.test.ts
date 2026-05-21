import {describe, expect, test} from 'vitest';
import {range, sortBy, uniqBy} from '../array';

describe('array', () => {
  test('range should work', () => {
    expect(range(0, 5)).toEqual([0, 1, 2, 3, 4, 5]);
    expect(range(3, 5)).toEqual([3, 4, 5]);
    expect(range(-3, 5)).toEqual([-3, -2, -1, 0, 1, 2, 3, 4, 5]);
  });

  test('sortBy should work', () => {
    const data = [
      {id: 4, name: 'Biz'},
      {id: 1, name: 'Foo'},
      {id: 3, name: 'Baz'},
      {id: 2, name: 'Bar'},
    ];
    expect(sortBy(data, 'id')).toEqual([
      {id: 1, name: 'Foo'},
      {id: 2, name: 'Bar'},
      {id: 3, name: 'Baz'},
      {id: 4, name: 'Biz'},
    ]);
    expect(sortBy(data, 'name')).toEqual([
      {id: 2, name: 'Bar'},
      {id: 3, name: 'Baz'},
      {id: 4, name: 'Biz'},
      {id: 1, name: 'Foo'},
    ]);
  });

  test('sortBy only accepts keys with comparable values', () => {
    const data = [
      {id: 1, tags: ['x']},
      {id: 2, tags: ['y']},
    ];

    expect(sortBy(data, 'id')).toHaveLength(2);

    // @ts-expect-error - `tags` holds an array, which has no sort order
    sortBy(data, 'tags');
  });

  test('uniqBy should work', () => {
    const data = [
      {id: 1, name: 'Foo'},
      {id: 2, name: 'Bar'},
      {id: 3, name: 'Foo'},
      {id: 1, name: 'Baz'},
    ];
    expect(uniqBy(data, (o) => o.id)).toEqual([
      {id: 1, name: 'Foo'},
      {id: 2, name: 'Bar'},
      {id: 3, name: 'Foo'},
    ]);
    expect(uniqBy(data, (o) => o.name)).toEqual([
      {id: 1, name: 'Foo'},
      {id: 2, name: 'Bar'},
      {id: 1, name: 'Baz'},
    ]);
  });
});
