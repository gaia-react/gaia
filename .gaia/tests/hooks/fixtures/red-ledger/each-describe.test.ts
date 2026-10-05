import {describe, expect, test} from 'vitest';

describe.each([{size: 1}, {size: 2}])('size $size', ({size}) => {
  test('is positive', () => {
    expect(size).toBeGreaterThan(0);
  });
});
