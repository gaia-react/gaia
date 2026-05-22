import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useDebounce} from '../useDebounce';

describe('useDebounce', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  test('returns the initial value immediately', () => {
    const {result} = renderHook(() => useDebounce('hello', 300));
    expect(result.current).toBe('hello');
  });

  test('does not update until delay elapses after a value change', () => {
    let value = 'hello';
    const {rerender, result} = renderHook(() => useDebounce(value, 300));

    value = 'world';
    rerender();

    // Not updated yet — delay has not elapsed
    expect(result.current).toBe('hello');

    act(() => {
      vi.advanceTimersByTime(299);
    });

    expect(result.current).toBe('hello');
  });

  test('updates to the latest value after delay elapses', () => {
    let value = 'hello';
    const {rerender, result} = renderHook(() => useDebounce(value, 300));

    value = 'world';
    rerender();

    act(() => {
      vi.advanceTimersByTime(300);
    });

    expect(result.current).toBe('world');
  });

  test('clears the pending timer on unmount — no late state update', () => {
    let value = 'hello';
    const {rerender, result, unmount} = renderHook(() =>
      useDebounce(value, 300)
    );

    value = 'world';
    rerender();

    unmount();

    act(() => {
      vi.advanceTimersByTime(300);
    });

    // Still reflects the value at the time of unmount
    expect(result.current).toBe('hello');
  });

  test('cancels pending update on rapid value changes and settles on the final value', () => {
    let value = 'a';
    const {rerender, result} = renderHook(() => useDebounce(value, 300));

    value = 'b';
    rerender();

    act(() => {
      vi.advanceTimersByTime(100);
    });

    value = 'c';
    rerender();

    act(() => {
      vi.advanceTimersByTime(300);
    });

    expect(result.current).toBe('c');
  });
});
