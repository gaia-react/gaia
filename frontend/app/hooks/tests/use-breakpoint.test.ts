import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useBreakpoint} from '../use-breakpoint';

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
      changeListeners = changeListeners.filter(
        (registeredListener) => registeredListener !== listener
      );
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

  test('subscribes once per breakpoint, not once per render', () => {
    mockMql.addEventListener.mockClear();
    mockMql.removeEventListener.mockClear();
    mockMatches = true;
    const maxSubscriptions = REACT_COMPILER_ENABLED ? 1 : Infinity;

    const {rerender, result, unmount} = renderHook(
      ({breakpoint}: {breakpoint: 'lg' | 'md'}) => useBreakpoint(breakpoint),
      {initialProps: {breakpoint: 'lg'}}
    );
    expect(result.current).toBe(true);

    rerender({breakpoint: 'lg'});
    expect(mockMql.addEventListener.mock.calls.length).toBeLessThanOrEqual(
      maxSubscriptions
    );
    expect(changeListeners).toHaveLength(1);

    mockMql.addEventListener.mockClear();
    mockMql.removeEventListener.mockClear();
    rerender({breakpoint: 'md'});
    expect(result.current).toBe(true);
    expect(mockMql.addEventListener.mock.calls.length).toBeGreaterThanOrEqual(
      1
    );
    expect(mockMql.addEventListener.mock.calls.length).toBeLessThanOrEqual(
      maxSubscriptions
    );
    expect(
      mockMql.removeEventListener.mock.calls.length
    ).toBeGreaterThanOrEqual(1);
    expect(mockMql.removeEventListener.mock.calls.length).toBeLessThanOrEqual(
      maxSubscriptions
    );
    expect(changeListeners).toHaveLength(1);

    unmount();
    expect(changeListeners).toHaveLength(0);
  });
});
