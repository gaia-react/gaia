import {expect, test} from '@playwright/test';

test.describe.configure({mode: 'parallel'});

test.describe('outer', () => {
  test.describe.serial('inner', () => {
    test('does a thing', () => {
      expect(true).toBe(true);
    });
  });
});

test.describe(() => {
  test('runs in an untitled group', () => {
    expect(true).toBe(true);
  });
});
