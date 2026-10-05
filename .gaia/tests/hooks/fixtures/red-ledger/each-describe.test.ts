import {describe, expect, test} from 'vitest';

describe.each`
  size
  ${1}
  ${2}
`('size $size', ({size}: {size: number}) => {
  test('is positive', () => {
    expect(size).toBeGreaterThan(0);
  });
});
