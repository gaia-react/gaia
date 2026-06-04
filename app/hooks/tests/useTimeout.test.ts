import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useTimeout} from '../useTimeout';

describe('useTimeout', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  test('complete is false immediately after mount', () => {
    const {result} = renderHook(() => useTimeout(500));
    expect(result.current).toBe(false);
  });

  test('complete becomes true after advancing timers past delay', () => {
    const {result} = renderHook(() => useTimeout(500));
    expect(result.current).toBe(false);

    act(() => {
      vi.advanceTimersByTime(500);
    });

    expect(result.current).toBe(true);
  });

  test('changing trigger resets complete to false', () => {
    let trigger = 'a';
    const {rerender, result} = renderHook(() => useTimeout(200, trigger));

    act(() => {
      vi.advanceTimersByTime(200);
    });

    expect(result.current).toBe(true);

    trigger = 'b';
    rerender();

    expect(result.current).toBe(false);

    act(() => {
      vi.advanceTimersByTime(200);
    });

    expect(result.current).toBe(true);
  });

  test('timeout is cleared on unmount — no late state update', () => {
    const {result, unmount} = renderHook(() => useTimeout(500));

    unmount();

    act(() => {
      vi.advanceTimersByTime(500);
    });

    // Still false; the timer was cleared before it fired
    expect(result.current).toBe(false);
  });
});
