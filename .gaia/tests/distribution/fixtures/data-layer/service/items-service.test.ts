import {http, HttpResponse} from 'msw/http';
import {delay} from 'msw/utils/delay';
import {describe, expect, test} from 'vitest';
import {createQueryClient} from '~/query-client';
import {attempt} from '~/services/api/helpers';
import {ITEMS_URLS} from '~/services/gaia/items';
import {itemKeys, itemQuery} from '~/services/gaia/items/queries';
import {
  createItem,
  getAllItems,
  getItemById,
} from '~/services/gaia/items/requests';
import {url} from './mocks/url';
// eslint-disable-next-line no-restricted-imports -- these tests register per-test MSW handlers on the suite's node server
import {server} from './test.server';

// How long the cancel test waits for the abort to reach the handler before
// reading the signal; far longer than an in-process abort takes.
const ABORT_WAIT_MILLISECONDS = 2000;

describe('scaffolded items service', () => {
  test('a 200 body that violates the schema resolves through attempt as a 500', async () => {
    server.use(
      http.get(url(ITEMS_URLS.itemsId), () =>
        HttpResponse.json({data: {display_name: 7}})
      )
    );

    const [error, result] = await attempt(async () => getItemById('1'));

    expect(error?.status).toBe(500);
    expect(error?.statusText.length).toBeGreaterThan(0);
    expect(result).toBeUndefined();
  });

  test('a plain Error thrown inside attempt still rejects', async () => {
    await expect(
      attempt(async () => {
        throw new Error('not a schema failure');
      })
    ).rejects.toThrow('not a schema failure');
  });

  test('createItem sends snake_case JSON and returns camelCase', async () => {
    let received: unknown;
    server.use(
      http.post(url(ITEMS_URLS.items), async ({request}) => {
        received = await request.json();

        return HttpResponse.json({data: {display_name: 'x', id: '1'}});
      })
    );

    const created = await createItem({displayName: 'x'});

    expect(received).toEqual({display_name: 'x'});
    expect(created).toEqual({displayName: 'x', id: '1'});
  });

  test('a server request starts with the server API_URL', async () => {
    let observed = '';
    server.use(
      http.get(url(ITEMS_URLS.items), ({request}) => {
        observed = request.url;

        return HttpResponse.json({data: []});
      })
    );

    await getAllItems();

    expect(process.env.API_URL).toBeTruthy();
    expect(observed.startsWith(process.env.API_URL ?? '<unset>')).toBe(true);
  });

  test('cancelQueries aborts the detail request in flight', async () => {
    let reached = false;
    let aborted = false;

    server.use(
      http.get(url(ITEMS_URLS.itemsId), async ({request}) => {
        reached = true;
        await Promise.race([
          new Promise((resolve) => {
            request.signal.addEventListener('abort', resolve, {once: true});
          }),
          delay(ABORT_WAIT_MILLISECONDS),
        ]);
        aborted = request.signal.aborted;

        return HttpResponse.json({data: {display_name: 'late', id: '1'}});
      })
    );

    const queryClient = createQueryClient();
    const pending = queryClient
      .query(itemQuery('1'))
      .then(() => 'resolved')
      .catch(() => 'cancelled');

    await expect.poll(() => reached).toBe(true);
    await queryClient.cancelQueries({queryKey: itemKeys.detail('1')});

    await expect(pending).resolves.toBe('cancelled');
    await expect.poll(() => aborted).toBe(true);
  });
});
