import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {renderHook} from 'vitest-browser-react';
import {useTimeout} from '../use-timeout';

describe('useTimeout', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  test('complete is false immediately after mount', async () => {
    const {result} = await renderHook(() => useTimeout(500));
    expect(result.current).toBe(false);
  });

  test('complete becomes true after advancing timers past delay', async () => {
    const {act, result} = await renderHook(() => useTimeout(500));
    expect(result.current).toBe(false);

    await act(() => {
      vi.advanceTimersByTime(500);
    });

    expect(result.current).toBe(true);
  });

  test('changing trigger resets complete to false', async () => {
    let trigger = 'a';
    const {act, rerender, result} = await renderHook(() =>
      useTimeout(200, trigger)
    );

    await act(() => {
      vi.advanceTimersByTime(200);
    });

    expect(result.current).toBe(true);

    trigger = 'b';
    await rerender();

    expect(result.current).toBe(false);

    await act(() => {
      vi.advanceTimersByTime(200);
    });

    expect(result.current).toBe(true);
  });

  test('timeout is cleared on unmount, with no late state update', async () => {
    const {act, result, unmount} = await renderHook(() => useTimeout(500));

    expect(vi.getTimerCount()).toBe(1);

    await unmount();

    expect(vi.getTimerCount()).toBe(0);

    await act(() => {
      vi.advanceTimersByTime(500);
    });

    // Still false; the timer was cleared before it fired
    expect(result.current).toBe(false);
  });
});
