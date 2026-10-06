import {http, HttpResponse} from 'msw';
import type {SetupWorker} from 'msw/browser';
import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import {getAllItems} from '~/services/gaia/items/requests';

// The origin the root loader would inject on window.process in the browser.
const INJECTED_ORIGIN = 'https://items-injected-api.test';

type ProcessHolder = {process?: unknown};

const originalProcess = (globalThis as ProcessHolder).process;

let worker: SetupWorker;

beforeAll(async () => {
  (globalThis as ProcessHolder).process = {env: {API_URL: INJECTED_ORIGIN}};
  ({worker} = await import('./worker'));
  await worker.start({onUnhandledRequest: 'error', quiet: true});
});

afterAll(() => {
  worker.stop();
  (globalThis as ProcessHolder).process = originalProcess;
});

describe('scaffolded items service in the browser', () => {
  test('a browser request starts with the injected API_URL', async () => {
    let observed = '';
    worker.use(
      http.get(`${INJECTED_ORIGIN}/items`, ({request}) => {
        observed = request.url;

        return HttpResponse.json({data: []});
      })
    );

    await getAllItems();

    expect(observed.startsWith(INJECTED_ORIGIN)).toBe(true);
  });
});
