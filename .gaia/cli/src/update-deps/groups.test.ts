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

  test('the Vitest browser stack moves with vitest, playwright stays its own group', () => {
    for (const name of [
      '@vitest/browser-playwright',
      'vitest-browser-react',
      'vitest',
    ]) {
      expect(resolveGroup(name)).toBe('vitest');
    }

    for (const name of ['@playwright/test', 'playwright']) {
      expect(resolveGroup(name)).toBe('playwright');
    }
  });

  test('the retired testing-library packages are no longer grouped', () => {
    for (const name of [
      '@testing-library/react',
      '@playwright-testing-library/test',
    ]) {
      expect(resolveGroup(name)).toBe(`singleton:${name}`);
    }
  });

  test('the Storybook test addons fall under the @storybook/ prefix', () => {
    expect(resolveGroup('@storybook/addon-vitest')).toBe('storybook');
    expect(resolveGroup('@storybook/addon-a11y')).toBe('storybook');
  });
});
