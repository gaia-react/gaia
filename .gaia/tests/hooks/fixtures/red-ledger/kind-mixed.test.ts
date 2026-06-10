import {expectTypeOf, expect, test} from 'vitest';

const double = (n: number): number => n * 2;

test('runtime plus expectTypeOf is runtime', () => {
  expect(double(2)).toBe(4);
  expectTypeOf<number>().toEqualTypeOf<number>();
});

test('runtime plus ts-expect-error is runtime', () => {
  expect(double(2)).toBe(4);
  // @ts-expect-error - double requires a number
  double('not a number');
});
