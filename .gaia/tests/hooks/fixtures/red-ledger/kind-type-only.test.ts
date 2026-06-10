import {expectTypeOf, test} from 'vitest';

const double = (n: number): number => n * 2;

test('type proof via expectTypeOf', () => {
  expectTypeOf<number>().toEqualTypeOf<number>();
});

test('type proof via ts-expect-error', () => {
  // @ts-expect-error - double requires a number
  double('not a number');
});
