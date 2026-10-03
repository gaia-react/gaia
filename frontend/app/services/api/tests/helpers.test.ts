import {HTTPError} from 'ky';
import {describe, expect, test} from 'vitest';
import type {ZodError} from 'zod';
import {z} from 'zod';
import {attempt} from '../helpers';

describe('attempt', () => {
  test('success — resolves to [undefined, result]', async () => {
    const result = await attempt(async () => 'ok');

    expect(result).toEqual([undefined, 'ok']);
  });

  test('HTTPError — resolves to [{status, statusText}, undefined]', async () => {
    const response = new Response('', {status: 404, statusText: 'Not Found'});
    const request = new Request('https://example.test');
    const httpError = new HTTPError(response, request, {} as never);

    const result = await attempt(async () => {
      throw httpError;
    });

    expect(result).toEqual([{status: 404, statusText: 'Not Found'}, undefined]);
  });

  test('ZodError — resolves to [{status: 500, statusText: error.message}, undefined]', async () => {
    let zodError: ZodError;

    try {
      z.string().parse(123);
    } catch (error) {
      zodError = error as ZodError;
    }

    const result = await attempt(async () => {
      throw zodError!;
    });

    expect(result).toEqual([
      {status: 500, statusText: zodError!.message},
      undefined,
    ]);
  });

  test('plain Error — rejects (re-thrown)', async () => {
    await expect(
      attempt(async () => {
        throw new Error('boom');
      })
    ).rejects.toThrow('boom');
  });

  test('unknown non-Error throw — resolves to [{status: 500, statusText: "Unknown error"}, undefined]', async () => {
    const result = await attempt(async () => {
      throw 'something unexpected';
    });

    expect(result).toEqual([
      {status: 500, statusText: 'Unknown error'},
      undefined,
    ]);
  });
});
