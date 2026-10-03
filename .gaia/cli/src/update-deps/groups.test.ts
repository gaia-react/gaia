import {describe, expect, test} from 'vitest';
import {resolveGroup, resolveGroupMembers} from './groups.js';

describe('companion groups', () => {
  test('lint-staged is an ungrouped singleton with no companions', () => {
    const group = resolveGroup('lint-staged');

    expect(group).toBe('singleton:lint-staged');
    expect(resolveGroupMembers(group, ['lint-staged', 'prettier'])).toEqual([]);
  });
});
