import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useBreakpoint} from '../use-breakpoint';

describe('useBreakpoint', () => {
  let changeListeners: (() => void)[] = [];
  let isMockMatching = false;

  const mockMediaQueryList = {
    addEventListener: vi.fn((_event: string, listener: () => void) => {
      changeListeners.push(listener);
    }),
    get matches() {
      return isMockMatching;
    },
    removeEventListener: vi.fn((_event: string, listener: () => void) => {
      changeListeners = changeListeners.filter(
        (registeredListener) => registeredListener !== listener
      );
    }),
  };

  beforeEach(() => {
    changeListeners = [];
    isMockMatching = false;
    vi.spyOn(window, 'matchMedia').mockReturnValue(
      mockMediaQueryList as unknown as MediaQueryList
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('returns false when media query does not match', () => {
    isMockMatching = false;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);
  });

  test('returns true when media query matches', () => {
    isMockMatching = true;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(true);
  });

  test('updates when MediaQueryList fires a change event', () => {
    isMockMatching = false;
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);

    act(() => {
      isMockMatching = true;
      changeListeners.forEach((listener) => listener());
    });

    expect(result.current).toBe(true);
  });

  test('removes the change listener on unmount', () => {
    const {unmount} = renderHook(() => useBreakpoint('md'));
    unmount();

    expect(mockMediaQueryList.removeEventListener).toHaveBeenCalledWith(
      'change',
      expect.any(Function)
    );
  });

  test('subscribes once per breakpoint, not once per render', () => {
    mockMediaQueryList.addEventListener.mockClear();
    mockMediaQueryList.removeEventListener.mockClear();
    isMockMatching = true;
    const maxSubscriptions = REACT_COMPILER_ENABLED ? 1 : Infinity;

    const {rerender, result, unmount} = renderHook(
      ({breakpoint}: {breakpoint: 'lg' | 'md'}) => useBreakpoint(breakpoint),
      {initialProps: {breakpoint: 'lg'}}
    );
    expect(result.current).toBe(true);

    rerender({breakpoint: 'lg'});
    expect(
      mockMediaQueryList.addEventListener.mock.calls.length
    ).toBeLessThanOrEqual(maxSubscriptions);
    expect(changeListeners).toHaveLength(1);

    mockMediaQueryList.addEventListener.mockClear();
    mockMediaQueryList.removeEventListener.mockClear();
    rerender({breakpoint: 'md'});
    expect(result.current).toBe(true);
    expect(
      mockMediaQueryList.addEventListener.mock.calls.length
    ).toBeGreaterThanOrEqual(1);
    expect(
      mockMediaQueryList.addEventListener.mock.calls.length
    ).toBeLessThanOrEqual(maxSubscriptions);
    expect(
      mockMediaQueryList.removeEventListener.mock.calls.length
    ).toBeGreaterThanOrEqual(1);
    expect(
      mockMediaQueryList.removeEventListener.mock.calls.length
    ).toBeLessThanOrEqual(maxSubscriptions);
    expect(changeListeners).toHaveLength(1);

    unmount();
    expect(changeListeners).toHaveLength(0);
  });
});
