import type {SetupWorker} from 'msw/browser';
import {http, HttpResponse} from 'msw/http';
import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import {z} from 'zod';
import {create} from '..';

const INJECTED_ORIGIN = 'https://injected-api.test';

const schema = z.object({data: z.object({ok: z.boolean()})});

type ProcessHolder = {process?: unknown};

const originalProcess = (globalThis as ProcessHolder).process;

let worker: SetupWorker;

beforeAll(async () => {
  // The mock handlers read process.env while their module loads, and a
  // browser has no process until the root loader injects one.
  (globalThis as ProcessHolder).process = {env: {API_URL: INJECTED_ORIGIN}};
  ({worker} = await import('../../../../test/worker'));
  await worker.start({onUnhandledFrame: 'error', quiet: true});
});

afterAll(async () => {
  await worker.stop();
  (globalThis as ProcessHolder).process = originalProcess;
});

describe('browser base URL', () => {
  test('uses the origin injected on window.process', async () => {
    let observed = '';
    worker.use(
      http.get(`${INJECTED_ORIGIN}/things`, ({request}) => {
        observed = request.url;

        return HttpResponse.json({data: {ok: true}});
      })
    );

    await create()('things', {schema});

    expect(observed.startsWith(INJECTED_ORIGIN)).toBe(true);
  });

  test('falls back to an origin-relative URL when no env is injected', async () => {
    (globalThis as ProcessHolder).process = undefined;
    let observed = '';
    worker.use(
      http.get('/things', ({request}) => {
        observed = request.url;

        return HttpResponse.json({data: {ok: true}});
      })
    );

    await create()('things', {schema});

    expect(observed).toBe(`${globalThis.location.origin}/things`);
  });
});
