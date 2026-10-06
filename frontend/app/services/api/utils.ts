import type {AfterResponseState, BeforeRequestState, Hooks, Options} from 'ky';
import type {StringifyOptions} from 'query-string';
import queryString from 'query-string';
import {tryCatch} from '~/utils/function';
import {toCamelCase, toSnakeCase} from '~/utils/object';

const requestToSnakeCase = async ({options, request}: BeforeRequestState) => {
  if (options.body && !(options.body instanceof FormData)) {
    const [error, parsed] = tryCatch(
      () => JSON.parse(options.body as string) as unknown
    );

    // A non-JSON body (plain string, URLSearchParams, etc.) is forwarded
    // unchanged rather than failing the request.
    if (error) {
      return;
    }

    const body = JSON.stringify(toSnakeCase(parsed));

    // eslint-disable-next-line unicorn/no-invalid-fetch-options
    return new Request(request, {body});
  }
};

const responseToCamelCase = async ({response}: AfterResponseState) => {
  const [, result] = await tryCatch(async () => {
    const original = await response.json();

    return Response.json(toCamelCase(original), response);
  });

  return result ?? (response.ok ? Response.json(null) : undefined);
};

export const getHooks = (
  isSnakeCaseEnabled?: boolean,
  hooks?: Hooks
): Hooks | undefined =>
  isSnakeCaseEnabled ?
    {
      ...hooks,
      afterResponse: [responseToCamelCase, ...(hooks?.afterResponse ?? [])],
      beforeRequest: [requestToSnakeCase, ...(hooks?.beforeRequest ?? [])],
    }
  : hooks;

export const appendSearchParams = (
  uri: string,
  options?: {
    arrayFormat?: NonNullable<StringifyOptions['arrayFormat']>;
    isSnakeCaseEnabled?: boolean;
    searchParams?: Record<string, unknown>;
  }
): string => {
  const {
    arrayFormat = 'comma',
    isSnakeCaseEnabled = false,
    searchParams,
  } = options ?? {};

  if (!searchParams) {
    return uri;
  }

  const casedParams =
    isSnakeCaseEnabled ?
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (toSnakeCase<any>(searchParams) as Record<string, unknown>)
    : searchParams;

  const safeParams = queryString.stringify(casedParams, {arrayFormat});
  const searchSeparator = uri.includes('?') ? '&' : '?';
  const search = safeParams ? `${searchSeparator}${safeParams}` : '';

  return `${uri}${search}`;
};

// Each rejected value sends the request to a different path: URL parsing
// resolves `.` and `..` segments, percent-encoded or not, and an empty
// segment collapses `items/:id` into the collection path `items/`.
const encodePathParam = (value: number | string): string => {
  const segment = String(value);

  if (segment === '') {
    throw new TypeError('Path param cannot be empty');
  }

  if (segment === '.' || segment === '..') {
    throw new TypeError(`Path param cannot be a dot segment: "${segment}"`);
  }

  return encodeURIComponent(segment);
};

// One pass over the placeholders, so a key that prefixes another (`:user`
// and `:userId`) cannot rewrite part of the longer one.
export const setPathParams = (
  url: string,
  pathParams?: Record<string, number | string>
): string =>
  pathParams ?
    url.replaceAll(/:(\w+)/g, (placeholder, key: string) =>
      Object.hasOwn(pathParams, key) ?
        encodePathParam(pathParams[key])
      : placeholder
    )
  : url;

export const getUri = (
  uri: string,
  {
    pathParams,
    ...options
  }: {
    arrayFormat?: NonNullable<StringifyOptions['arrayFormat']>;
    isSnakeCaseEnabled?: boolean;
    pathParams?: Record<string, number | string>;
    searchParams?: Record<string, unknown>;
  } = {}
): string => appendSearchParams(setPathParams(uri, pathParams), options);

export const getBaseUrl = (): string => {
  // server api call; API_URL is validated at startup in env.server
  if (typeof window === 'undefined') return process.env.API_URL ?? '';

  // client api call; window.process is injected by the root loader and absent
  // in some browser contexts, though the global Window type declares it
  const injectedProcess = (window as Partial<Pick<Window, 'process'>>).process;

  return injectedProcess?.env.API_URL ?? '';
};

// Merges per-request auth/language onto caller-supplied headers; never stored module-side to prevent SSR token cross-contamination.
export const buildRequestHeaders = (
  headers: Options['headers'],
  token?: string,
  language?: string
): Headers => {
  const merged = new Headers(headers as HeadersInit | undefined);

  if (token) {
    merged.set('Authorization', `Bearer ${token}`);
  }

  if (language) {
    merged.set('Accept-Language', language);
  }

  return merged;
};
