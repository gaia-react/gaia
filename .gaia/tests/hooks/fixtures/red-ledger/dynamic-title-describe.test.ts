import {describe, expect, test} from 'vitest';

const suiteName = 'computed';

describe(suiteName, () => {
  test('is reached', () => {
    expect(suiteName).toBe('computed');
  });
});
