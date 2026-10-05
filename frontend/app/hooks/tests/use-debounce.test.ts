import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {renderHook} from 'vitest-browser-react';
import {useDebounce} from '../use-debounce';

describe('useDebounce', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  test('returns the initial value immediately', async () => {
    const {result} = await renderHook(() => useDebounce('hello', 300));
    expect(result.current).toBe('hello');
  });

  test('does not update until delay elapses after a value change', async () => {
    let value = 'hello';
    const {act, rerender, result} = await renderHook(() =>
      useDebounce(value, 300)
    );

    value = 'world';
    await rerender();

    // Not updated yet; delay has not elapsed
    expect(result.current).toBe('hello');

    await act(() => {
      vi.advanceTimersByTime(299);
    });

    expect(result.current).toBe('hello');
  });

  test('updates to the latest value after delay elapses', async () => {
    let value = 'hello';
    const {act, rerender, result} = await renderHook(() =>
      useDebounce(value, 300)
    );

    value = 'world';
    await rerender();

    await act(() => {
      vi.advanceTimersByTime(300);
    });

    expect(result.current).toBe('world');
  });

  test('clears the pending timer on unmount — no late state update', async () => {
    let value = 'hello';
    const {act, rerender, result, unmount} = await renderHook(() =>
      useDebounce(value, 300)
    );

    value = 'world';
    await rerender();

    await unmount();

    await act(() => {
      vi.advanceTimersByTime(300);
    });

    // Still reflects the value at the time of unmount
    expect(result.current).toBe('hello');
  });

  test('cancels pending update on rapid value changes and settles on the final value', async () => {
    let value = 'a';
    const {act, rerender, result} = await renderHook(() =>
      useDebounce(value, 300)
    );

    value = 'b';
    await rerender();

    await act(() => {
      vi.advanceTimersByTime(100);
    });

    value = 'c';
    await rerender();

    await act(() => {
      vi.advanceTimersByTime(300);
    });

    expect(result.current).toBe('c');
  });
});
