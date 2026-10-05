import {describe, expect, test} from 'vitest';
import {isFrameworkComponent} from './framework-denylist.js';

describe('isFrameworkComponent', () => {
  test('filters the React Router and Remix internal names', () => {
    expect(isFrameworkComponent('RenderedRoute')).toBe(true);
    expect(isFrameworkComponent('Outlet')).toBe(true);
    expect(isFrameworkComponent('fetcher.Form')).toBe(true);
  });

  test('filters a lucide icon wrapper and its anonymous base, both ForwardRef records', () => {
    expect(isFrameworkComponent('Sun', 'ForwardRef')).toBe(true);
    expect(isFrameworkComponent('X', 'ForwardRef')).toBe(true);
    expect(isFrameworkComponent('Unknown', 'ForwardRef')).toBe(true);
  });

  test('keeps an app component that shares an icon name but is not a ForwardRef', () => {
    expect(isFrameworkComponent('Sun', 'Function')).toBe(false);
    expect(isFrameworkComponent('Copy', 'Memo')).toBe(false);
    expect(isFrameworkComponent('Sun')).toBe(false);
  });

  test('does not filter pack-prefixed icon names on name alone', () => {
    expect(isFrameworkComponent('IconBase')).toBe(false);
    expect(isFrameworkComponent('FaGithub')).toBe(false);
  });
});
