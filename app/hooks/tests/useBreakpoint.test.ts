import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useBreakpoint} from '../useBreakpoint';

describe('useBreakpoint', () => {
  const originalInnerWidth = window.innerWidth;

  beforeEach(() => {
    vi.spyOn(window, 'addEventListener');
    vi.spyOn(window, 'removeEventListener');
  });

  afterEach(() => {
    Object.defineProperty(window, 'innerWidth', {
      value: originalInnerWidth,
      writable: true,
    });
    vi.restoreAllMocks();
  });

  test('returns true when innerWidth meets the breakpoint threshold', () => {
    Object.defineProperty(window, 'innerWidth', {value: 1024, writable: true});
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(true);
  });

  test('returns false when innerWidth is below the breakpoint threshold', () => {
    Object.defineProperty(window, 'innerWidth', {value: 600, writable: true});
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);
  });

  test('updates on window resize events', () => {
    Object.defineProperty(window, 'innerWidth', {value: 600, writable: true});
    const {result} = renderHook(() => useBreakpoint('lg'));
    expect(result.current).toBe(false);

    act(() => {
      Object.defineProperty(window, 'innerWidth', {
        value: 1200,
        writable: true,
      });
      window.dispatchEvent(new Event('resize'));
    });

    expect(result.current).toBe(true);
  });

  test('removes the resize listener on unmount', () => {
    const {unmount} = renderHook(() => useBreakpoint('md'));
    unmount();

    expect(window.removeEventListener).toHaveBeenCalledWith(
      'resize',
      expect.any(Function)
    );
  });
});
