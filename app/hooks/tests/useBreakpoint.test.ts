import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useBreakpoint} from '../useBreakpoint';

describe('useBreakpoint', () => {
  let changeListeners: (() => void)[] = [];
  let mockMatches = false;

  const mockMql = {
    addEventListener: vi.fn((_event: string, listener: () => void) => {
      changeListeners.push(listener);
    }),
    get matches() {
      return mockMatches;
    },
    removeEventListener: vi.fn((_event: string, listener: () => void) => {
      changeListeners = changeListeners.filter((l) => l !== listener);
    }),
  };

  beforeEach(() => {
    changeListeners = [];
    mockMatches = false;
    vi.spyOn(window, 'matchMedia').mockReturnValue(
      mockMql as unknown as MediaQueryList
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('returns false when media query does not match', () => {
    mockMatches = false;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);
  });

  test('returns true when media query matches', () => {
    mockMatches = true;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(true);
  });

  test('updates when MediaQueryList fires a change event', () => {
    mockMatches = false;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);

    act(() => {
      mockMatches = true;
      changeListeners.forEach((listener) => listener());
    });

    expect(result.current).toBe(true);
  });

  test('removes the change listener on unmount', () => {
    const {unmount} = renderHook(() => useBreakpoint('md'));
    unmount();

    expect(mockMql.removeEventListener).toHaveBeenCalledWith(
      'change',
      expect.any(Function)
    );
  });
});
