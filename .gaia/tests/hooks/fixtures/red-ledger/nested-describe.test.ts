import {describe, expect, test} from 'vitest';

describe('outer', () => {
  describe('inner', () => {
    test('does a thing', () => {
      expect(true).toBe(true);
    });
  });
});
