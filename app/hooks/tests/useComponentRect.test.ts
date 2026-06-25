import {act, renderHook} from '@testing-library/react';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {useComponentRect} from '../useComponentRect';

describe('useComponentRect', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(window, 'addEventListener');
    vi.spyOn(window, 'removeEventListener');
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  test('returns a zero-rect before any measurement', () => {
    const ref = {current: null};
    const {result} = renderHook(() => useComponentRect(ref));

    expect(result.current).toMatchObject({
      bottom: 0,
      height: 0,
      left: 0,
      right: 0,
      top: 0,
      width: 0,
      x: 0,
      y: 0,
    });
  });

  test('calls getBoundingClientRect on the ref element and updates state', () => {
    const mockRect = {
      bottom: 100,
      height: 50,
      left: 10,
      right: 110,
      toJSON: () => {},
      top: 50,
      width: 100,
      x: 10,
      y: 50,
    } as DOMRect;

    const element = document.createElement('div');
    element.getBoundingClientRect = vi.fn().mockReturnValue(mockRect);

    const ref = {current: element};

    const {result} = renderHook(() => useComponentRect(ref));

    act(() => {
      vi.runAllTimers();
    });

    expect(element.getBoundingClientRect).toHaveBeenCalledWith();
    expect(result.current).toMatchObject({
      height: 50,
      width: 100,
    });
  });

  test('removes resize and scroll listeners on unmount', () => {
    const element = document.createElement('div');
    element.getBoundingClientRect = vi.fn().mockReturnValue({
      bottom: 0,
      height: 0,
      left: 0,
      right: 0,
      toJSON: () => {},
      top: 0,
      width: 0,
      x: 0,
      y: 0,
    });

    const ref = {current: element};
    const {unmount} = renderHook(() => useComponentRect(ref));

    act(() => {
      vi.runAllTimers();
    });

    unmount();

    expect(window.removeEventListener).toHaveBeenCalledWith(
      'resize',
      expect.any(Function)
    );
    expect(window.removeEventListener).toHaveBeenCalledWith(
      'scroll',
      expect.any(Function),
      expect.objectContaining({passive: true})
    );
  });
});
