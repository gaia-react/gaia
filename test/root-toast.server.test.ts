// @vitest-environment jsdom
import {RouterContextProvider} from 'react-router';
import {redirectWithSuccess, setToastCookieOptions} from 'remix-toast';
import {describe, expect, test} from 'vitest';
import {env} from '~/env.server';
import {i18nextMiddleware} from '~/middleware/i18next';
import {loader} from '~/root';

// Nothing in the app emits a toast yet, so this is the only thing exercising
// remix-toast's flash cookie against the installed React Router. A break there
// is silent in the app: the root loader returns no toast and nothing throws.
setToastCookieOptions({secrets: [env.SESSION_SECRET]});

const extractCookiePair = (setCookie: string) => setCookie.split(';', 1)[0];

const runRootLoader = async (cookie?: string) => {
  const url = new URL('http://localhost/');
  const request = new Request(url, {
    headers: cookie ? {Cookie: cookie} : {},
  });
  const context = new RouterContextProvider();
  const args = {context, params: {}, pattern: '/', request, url};

  let result: Awaited<ReturnType<typeof loader>> | undefined;

  await i18nextMiddleware(args, async () => {
    result = await loader(args);

    return new Response();
  });

  if (!result) throw new Error('root loader did not run');

  return result;
};

describe('root loader toast round trip', () => {
  test('reads a toast emitted by an action exactly once', async () => {
    const redirect = await redirectWithSuccess('/', 'Saved');
    const [emitted] = redirect.headers.getSetCookie();

    expect(emitted).toBeDefined();

    const first = await runRootLoader(extractCookiePair(emitted));

    expect(first.data.toast).toMatchObject({message: 'Saved', type: 'success'});

    // The flash is consumed by re-committing the session empty, not by
    // expiring the cookie, so the proof is a replay of what came back.
    const toastCookieName = extractCookiePair(emitted).split('=', 1)[0];
    const returned = new Headers(first.init?.headers)
      .getSetCookie()
      .find((setCookie) => setCookie.startsWith(`${toastCookieName}=`));

    expect(returned).toBeDefined();

    const second = await runRootLoader(extractCookiePair(returned ?? ''));

    expect(second.data.toast).toBeUndefined();
  });

  test('returns no toast when none was emitted', async () => {
    const {data} = await runRootLoader();

    expect(data.toast).toBeUndefined();
  });
});
