import {expect, test} from 'vitest';

test('passes fine', () => {
  expect(1).toBe(1);
});

test('fails on assertion', () => {
  expect(1).toBe(2);
});
