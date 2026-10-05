import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {renderHook} from 'vitest-browser-react';
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

  test('returns false when media query does not match', async () => {
    isMockMatching = false;
    const {result} = await renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);
  });

  test('returns true when media query matches', async () => {
    isMockMatching = true;
    const {result} = await renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(true);
  });

  test('updates when MediaQueryList fires a change event', async () => {
    isMockMatching = false;
    const {act, result} = await renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);

    await act(() => {
      isMockMatching = true;
      changeListeners.forEach((listener) => listener());
    });

    expect(result.current).toBe(true);
  });

  test('removes the change listener on unmount', async () => {
    const {unmount} = await renderHook(() => useBreakpoint('md'));
    await unmount();

    expect(mockMediaQueryList.removeEventListener).toHaveBeenCalledWith(
      'change',
      expect.any(Function)
    );
  });

  test('subscribes once per breakpoint, not once per render', async () => {
    mockMediaQueryList.addEventListener.mockClear();
    mockMediaQueryList.removeEventListener.mockClear();
    isMockMatching = true;
    const maxSubscriptions = REACT_COMPILER_ENABLED ? 1 : Infinity;

    const {rerender, result, unmount} = await renderHook(
      (props?: {breakpoint: 'lg' | 'md'}) =>
        useBreakpoint(props?.breakpoint ?? 'lg'),
      {initialProps: {breakpoint: 'lg'}}
    );
    expect(result.current).toBe(true);

    await rerender({breakpoint: 'lg'});
    expect(
      mockMediaQueryList.addEventListener.mock.calls.length
    ).toBeLessThanOrEqual(maxSubscriptions);
    expect(changeListeners).toHaveLength(1);

    mockMediaQueryList.addEventListener.mockClear();
    mockMediaQueryList.removeEventListener.mockClear();
    await rerender({breakpoint: 'md'});
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

    await unmount();
    expect(changeListeners).toHaveLength(0);
  });
});
