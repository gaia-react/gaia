import {describe, expect, test} from 'vitest';
import {sleep, tryCatch} from '../function';

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
