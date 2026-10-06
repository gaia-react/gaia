/* eslint-disable testing-library/prefer-screen-queries -- vitest-browser-react's render result holds Vitest browser locators, not Testing Library queries */
import type {ActionFunction, LoaderFunction} from 'react-router';
import {createRoutesStub, Outlet, useNavigation} from 'react-router';
import {QueryClientProvider, useIsFetching} from '@tanstack/react-query';
import type {QueryClient} from '@tanstack/react-query';
import type {SetupWorker} from 'msw/browser';
import {afterAll, beforeAll, beforeEach, describe, expect, test} from 'vitest';
import {render} from 'vitest-browser-react';
import {userEvent} from 'vitest/browser';
import {
  createQueryClient,
  QUERY_DEFAULT_OPTIONS,
  setBrowserQueryClient,
} from '~/query-client';
import * as listRoute from '~/routes/_public.items';
import * as detailRoute from '~/routes/_public.items_.$id';

// Requests go to this origin, injected on window.process the way the root
// loader injects the server env, so the mock handlers and the service agree.
const API_ORIGIN = 'https://items-flow-api.test';

type Counts = {detail: number; list: number};

type ProcessHolder = {process?: unknown};

const originalProcess = (globalThis as ProcessHolder).process;

let worker: SetupWorker;
let resetItems: (seed?: {display_name: string; id: string}[]) => Promise<void>;
let queryClient: QueryClient;

const counts: Counts = {detail: 0, list: 0};

const resetCounts = () => {
  counts.detail = 0;
  counts.list = 0;
};

// A route module types its data functions with its generated args, which the
// stub's generic route args do not satisfy; the stub only forwards them.
const asLoader = (loader: (args: never) => unknown) => loader as LoaderFunction;
const asAction = (action: (args: never) => unknown) => action as ActionFunction;

// Exposes the router's navigation state and the client's in-flight fetch
// count, so the test reads the counters only once both have settled.
const Shell = () => {
  const navigation = useNavigation();
  const fetching = useIsFetching();

  return (
    <>
      <output aria-label="router state">
        {navigation.state === 'idle' && fetching === 0 ? 'settled' : 'busy'}
      </output>
      <Outlet />
    </>
  );
};

const ItemsStub = createRoutesStub([
  {
    children: [
      {
        action: asAction(listRoute.clientAction),
        Component: listRoute.default,
        HydrateFallback: listRoute.HydrateFallback,
        loader: asLoader(listRoute.clientLoader),
        path: '/items',
      },
      {
        action: asAction(detailRoute.clientAction),
        Component: detailRoute.default,
        HydrateFallback: detailRoute.HydrateFallback,
        loader: asLoader(detailRoute.clientLoader),
        path: '/items/:id',
      },
    ],
    Component: Shell,
    path: '/',
  },
]);

beforeAll(async () => {
  // The mock handlers read process.env while their modules load, and a
  // browser has no process until the root loader injects one.
  (globalThis as ProcessHolder).process = {env: {API_URL: API_ORIGIN}};
  ({worker} = await import('./worker'));
  const {default: itemHandlers} = await import('./mocks/items');
  ({resetItems} = await import('./mocks/items/data'));
  worker.use(...itemHandlers);
  worker.events.on('request:start', ({request}) => {
    if (request.method !== 'GET') return;
    const {pathname} = new URL(request.url);

    if (pathname === '/items') counts.list += 1;
    if (pathname === '/items/1') counts.detail += 1;
  });
  await worker.start({onUnhandledFrame: 'error', quiet: true});
});

afterAll(async () => {
  await worker.stop();
  (globalThis as ProcessHolder).process = originalProcess;
});

beforeEach(async () => {
  await resetItems([{display_name: 'Original name', id: '1'}]);
  // A fresh client per test, registered as the browser client so the route
  // modules' clientLoader and clientAction use the one the provider holds.
  queryClient = createQueryClient({
    ...QUERY_DEFAULT_OPTIONS,
    queries: {...QUERY_DEFAULT_OPTIONS.queries, retry: false},
  });
  setBrowserQueryClient(queryClient);
});

// Walks list -> detail -> rename -> redirect back to the list, resetting the
// counters immediately before each navigation and asserting them once the new
// screen shows and the router and the client are both idle.
const runFlow = async () => {
  resetCounts();
  const view = await render(
    <QueryClientProvider client={queryClient}>
      <ItemsStub initialEntries={['/items']} />
    </QueryClientProvider>
  );

  const settled = async () => {
    await expect
      .element(view.getByRole('status', {name: 'router state'}))
      .toHaveTextContent('settled');
  };

  // The list renders only once its clientLoader has filled the cache, so the
  // count is read before the item name: a client that kept an earlier run's
  // cache renders the list with no request at all.
  await expect.element(view.getByRole('list')).toBeVisible();
  await settled();
  expect(counts.list, 'list GETs for the initial visit').toBe(1);
  await expect
    .element(view.getByRole('link', {name: 'Original name'}))
    .toBeVisible();

  resetCounts();
  await userEvent.click(view.getByRole('link', {name: 'Original name'}));
  await expect
    .element(view.getByRole('heading', {level: 1, name: 'Items detail'}))
    .toBeVisible();
  await settled();
  expect(counts.detail, 'detail GETs for the visit').toBe(1);
  expect(counts.list, 'list GETs while on the detail route').toBe(0);

  resetCounts();
  await userEvent.clear(view.getByLabelText('Display name'));
  await userEvent.type(view.getByLabelText('Display name'), 'Renamed item');
  await userEvent.click(view.getByRole('button', {name: 'Save'}));
  await expect
    .element(view.getByRole('link', {name: 'Renamed item'}))
    .toBeVisible();
  await settled();
  expect(counts.list, 'list GETs after the redirect').toBe(1);
  // The invalidation may refetch the detail query while it is still mounted.
  expect(counts.detail, 'detail GETs after the rename').toBeLessThanOrEqual(1);
};

describe('items list to detail to list flow', () => {
  test('first run: the list shows the rename after the redirect', async () => {
    expect.hasAssertions();
    await runFlow();
  });

  test('second run: a fresh client fetches the same counts again', async () => {
    expect.hasAssertions();
    await runFlow();
  });
});
