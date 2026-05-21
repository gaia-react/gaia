export const toHeadersObject = (
  headers?: Headers | Record<string, string>
): Record<string, string> | undefined =>
  headers ?
    headers instanceof Headers ?
      Object.fromEntries(headers)
    : headers
  : undefined;

/*
  True only for same-origin, path-relative redirect targets. Rejects
  protocol-relative ("//host") and backslash ("/\host") forms, which
  browsers normalize to an absolute off-site URL — the open-redirect vector.
*/
export const isLocalRedirect = (
  url: null | string | undefined
): url is string =>
  url != null &&
  url.startsWith('/') &&
  !url.startsWith('//') &&
  !url.startsWith('/\\');
