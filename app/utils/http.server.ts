import type {HeadersFunction} from 'react-router';

export const isProductionHost = (request: Request): boolean =>
  request.headers.get('host') === 'domain.tld';

export const getContentSecurityPolicy = (nonce: string): string =>
  [
    `default-src 'self'`,
    `script-src 'self' 'report-sample' 'nonce-${nonce}'`,
    `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com`,
    `font-src 'self' https://fonts.gstatic.com`,
    `img-src 'self' data:`,
    `connect-src 'self'`,
    `object-src 'none'`,
    `base-uri 'self'`,
    `form-action 'self'`,
    `frame-ancestors 'none'`,
  ].join('; ');

// based on Jacob Paris' blog post:
// https://www.jacobparis.com/content/remix-headers

const SETTABLE_HEADERS = ['Cache-Control', 'Vary', 'Server-Timing'];

export const headers: HeadersFunction = ({loaderHeaders}) => {
  const safeHeaders = new Headers();

  SETTABLE_HEADERS.forEach((header) => {
    if (loaderHeaders.has(header)) {
      safeHeaders.set(header, loaderHeaders.get(header)!);
    }
  });

  return safeHeaders;
};
