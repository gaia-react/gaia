import {describe, expect, test} from 'vitest';
import {resolveGroup, resolveGroupMembers} from './groups.js';

describe('companion groups', () => {
  test('lint-staged is an ungrouped singleton with no companions', () => {
    const group = resolveGroup('lint-staged');

    expect(group).toBe('singleton:lint-staged');
    expect(resolveGroupMembers(group, ['lint-staged', 'prettier'])).toEqual([]);
  });

  test('the shadcn component layer packages move as one group', () => {
    const members = [
      '@base-ui/react',
      'class-variance-authority',
      'lucide-react',
      'shadcn',
      'tw-animate-css',
    ];

    for (const name of members) expect(resolveGroup(name)).toBe('shadcn');

    expect(resolveGroupMembers('shadcn', ['shadcn', 'lucide-react'])).toEqual(
      expect.arrayContaining(['shadcn', 'lucide-react'])
    );
  });
});
