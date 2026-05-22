/* eslint-disable max-params, no-console */
/**
 * By default, Remix will handle generating the HTTP Response for you.
 * You are free to delete this file if you'd like to, but if you ever want it revealed again, you can run `npx remix reveal` ✨
 * For more information, see https://remix.run/file-conventions/entry.server
 */

import type {RenderToPipeableStreamOptions} from 'react-dom/server';
import type {EntryContext, RouterContextProvider} from 'react-router';
import {renderToPipeableStream} from 'react-dom/server';
import {I18nextProvider} from 'react-i18next';
import {ServerRouter} from 'react-router';
import {createReadableStreamFromReadable} from '@react-router/node';
import {createInstance} from 'i18next';
import {isbot} from 'isbot';
import {randomBytes} from 'node:crypto';
import {PassThrough} from 'node:stream';
import i18nConfig from '~/i18n';
import {getInstance} from '~/middleware/i18next';
import {getContentSecurityPolicy} from '~/utils/http.server';
import {NonceProvider} from '~/utils/nonce';
import {env} from './env.server';
import 'dotenv/config';

if (env.NODE_ENV !== 'production' && env.MSW_ENABLED) {
  const {startApiMocks} = await import('../test/msw.server');
  startApiMocks();
}

const streamTimeout = 5000;

const handleRequest = async (
  request: Request,
  responseStatusCode: number,
  responseHeaders: Headers,
  entryContext: EntryContext,
  routerContext: RouterContextProvider
) => {
  let shellRendered = false;

  const nonce = randomBytes(16).toString('hex');

  const url = new URL(request.url);

  // disallow www subdomain
  if (url.host.startsWith('www.')) {
    url.host = url.host.slice(4);

    return Response.redirect(url.toString(), 301);
  }

  // remove trailing slash on all routes
  if (url.pathname !== '/' && url.pathname.endsWith('/')) {
    url.pathname = url.pathname.slice(0, -1);

    return Response.redirect(url.toString(), 301);
  }

  // force lowercase URLs to prevent duplicate content for SEO
  if (url.pathname !== url.pathname.toLowerCase()) {
    url.pathname = url.pathname.toLowerCase();

    return Response.redirect(url.toString(), 301);
  }

  const userAgent = request.headers.get('user-agent') ?? '';

  const i18n = (() => {
    try {
      return getInstance(routerContext);
    } catch {
      // Middleware didn't run (e.g. unmatched routes like Chrome DevTools probes)
      const fallback = createInstance();

      void fallback.init({...i18nConfig, lng: i18nConfig.fallbackLng});

      return fallback;
    }
  })();

  const readyOption: keyof RenderToPipeableStreamOptions =
    (userAgent && isbot(userAgent)) || entryContext.isSpaMode ?
      'onAllReady'
    : 'onShellReady';

  return new Promise((resolve, reject) => {
    const {abort, pipe} = renderToPipeableStream(
      <NonceProvider value={nonce}>
        <I18nextProvider i18n={i18n}>
          <ServerRouter
            context={entryContext}
            nonce={nonce}
            url={request.url}
          />
        </I18nextProvider>
      </NonceProvider>,
      {
        nonce,
        onError: (error: unknown) => {
          // eslint-disable-next-line sonarjs/no-parameter-reassignment
          responseStatusCode = 500;

          if (shellRendered) {
            console.error(error);
          }
        },
        onShellError: (error: unknown) => {
          reject(error);
        },
        [readyOption]: () => {
          shellRendered = true;
          const body = new PassThrough();
          const stream = createReadableStreamFromReadable(body);

          responseHeaders.set('Content-Type', 'text/html');

          // Report-Only: React Router's production build does not apply the nonce
          // to its single-fetch stream scripts, so enforcing would block
          // hydration. Tracking: https://github.com/remix-run/react-router/issues/15083
          // Switch the header name to 'Content-Security-Policy' to enforce once fixed.
          responseHeaders.set(
            'Content-Security-Policy-Report-Only',
            getContentSecurityPolicy(nonce)
          );

          // Security response headers
          responseHeaders.set(
            'Strict-Transport-Security',
            'max-age=31536000; includeSubDomains'
          );
          responseHeaders.set('X-Content-Type-Options', 'nosniff');
          responseHeaders.set('X-Frame-Options', 'DENY');

          resolve(
            new Response(stream, {
              headers: responseHeaders,
              status: responseStatusCode,
            })
          );

          pipe(body);
        },
      }
    );

    setTimeout(abort, streamTimeout + 1000);
  });
};

export default handleRequest;
