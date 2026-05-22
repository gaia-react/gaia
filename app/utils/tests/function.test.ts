import {describe, expect, test, vi} from 'vitest';
import {compose, noop, sleep, tryCatch} from '../function';

describe('function utils', () => {
  test('tryCatch async result', async () => {
    expect(
      await tryCatch(async (value: number) => {
        await sleep(100);

        return 10 / value;
      }, 5)
    ).toEqual([undefined, 2]);
  });

  test('tryCatch async error', async () => {
    expect(
      await tryCatch(async () => {
        await sleep(100);

        throw new Error('failed');
      })
    ).toEqual([new Error('failed'), undefined]);
  });

  test('tryCatch sync result', async () => {
    expect(tryCatch((value: number) => 10 / value, 5)).toEqual([undefined, 2]);
  });

  test('tryCatch sync error', async () => {
    expect(
      tryCatch(() => {
        throw new Error('failed');
      })
    ).toEqual([new Error('failed'), undefined]);
  });

  test('tryCatch preserves falsy sync results as success', () => {
    expect(tryCatch(() => 0)).toEqual([undefined, 0]);
    expect(tryCatch(() => false)).toEqual([undefined, false]);
    expect(tryCatch(() => '')).toEqual([undefined, '']);
    expect(tryCatch(() => null)).toEqual([undefined, null]);
  });
});

const double = (x: number) => x * 2;
const addOne = (x: number) => x + 1;

describe('noop', () => {
  test('is callable without throwing', () => {
    expect(() => noop()).not.toThrow();
  });
});

describe('compose', () => {
  test('applies functions right-to-left', () => {
    const doubleThenAdd = compose(addOne, double);
    expect(doubleThenAdd(3)).toBe(7);
  });

  test('handles a single function', () => {
    const spy = vi.fn((x: number) => x * 3);
    const composed = compose(spy);
    expect(composed(4)).toBe(12);
    expect(spy).toHaveBeenCalledWith(4);
  });
});
