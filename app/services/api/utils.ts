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
  useSnakeCase?: boolean,
  hooks?: Hooks
): Hooks | undefined =>
  useSnakeCase ?
    {
      ...hooks,
      afterResponse: [responseToCamelCase, ...(hooks?.afterResponse ?? [])],
      beforeRequest: [requestToSnakeCase, ...(hooks?.beforeRequest ?? [])],
    }
  : hooks;

export const appendSearchParams = (
  uri: string,
  options?: {
    arrayFormat?: StringifyOptions['arrayFormat'];
    searchParams?: Record<string, unknown>;
    useSnakeCase?: boolean;
  }
): string => {
  const {
    arrayFormat = 'comma',
    searchParams,
    useSnakeCase = true,
  } = options ?? {};

  if (!searchParams) {
    return uri;
  }

  const casedParams =
    useSnakeCase ?
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (toSnakeCase<any>(searchParams) as Record<string, unknown>)
    : searchParams;

  const safeParams = queryString.stringify(casedParams, {arrayFormat});
  const q = uri.includes('?') ? '&' : '?';
  const search = safeParams ? `${q}${safeParams}` : '';

  return `${uri}${search}`;
};

export const setPathParams = (
  url: string,
  pathParams?: Record<string, number | string>
): string =>
  pathParams ?
    Object.entries(pathParams).reduce(
      (acc, [key, value]) => acc.replace(`:${key}`, String(value)),
      url
    )
  : url;

export const getUri = (
  uri: string,
  {
    pathParams,
    ...options
  }: {
    arrayFormat?: StringifyOptions['arrayFormat'];
    pathParams?: Record<string, number | string>;
    searchParams?: Record<string, unknown>;
    useSnakeCase?: boolean;
  } = {}
): string => appendSearchParams(setPathParams(uri, pathParams), options);

export const getBaseUrl = (): string => {
  // server api call — API_URL is validated at startup in env.server
  if (typeof window === 'undefined') return process.env.API_URL ?? '';

  // client api call
  if (window.process.env.API_URL) return window.process.env.API_URL;

  // fallback
  return '';
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
