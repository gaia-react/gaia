import {z} from 'zod';

export const toHeadersObject = (
  headers?: Headers | Record<string, string>
): Record<string, string> | undefined =>
  headers ?
    headers instanceof Headers ?
      Object.fromEntries(headers)
    : headers
  : undefined;

// A reserved .invalid host, so no real origin can equal it.
const LOCAL_ORIGIN = 'https://local.invalid';

/*
  The same-origin path a redirect target resolves to, or undefined when it
  leaves this origin. The target is resolved the way a browser resolves a
  Location header, so the consumer redirects to the returned path, never the
  raw input. A resolved path starting with "//" is rejected too, because a
  browser reads it as another host. A target the URL parser cannot resolve is
  undefined, never a throw.
*/
export const resolveLocalRedirect = (
  url: null | string | undefined
): string | undefined => {
  if (!url?.startsWith('/')) return undefined;

  let resolvedUrl: URL;

  try {
    resolvedUrl = new URL(url, LOCAL_ORIGIN);
  } catch {
    return undefined;
  }

  if (
    resolvedUrl.origin !== LOCAL_ORIGIN ||
    resolvedUrl.pathname.startsWith('//')
  ) {
    return undefined;
  }

  return resolvedUrl.pathname + resolvedUrl.search + resolvedUrl.hash;
};

/** A form field that parses to the resolved same-origin path, or fails. */
export const LocalRedirectSchema = z
  .string()
  .transform(resolveLocalRedirect)
  .pipe(z.string({error: 'Redirect must stay on this site'}));
