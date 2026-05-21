import type {AfterResponseState, BeforeRequestState, Hooks, Options} from 'ky';
import type {StringifyOptions} from 'query-string';
import queryString from 'query-string';
import {tryCatch} from '~/utils/function';
import {toCamelCase, toSnakeCase} from '~/utils/object';

const requestToSnakeCase = async ({options, request}: BeforeRequestState) => {
  if (options.body && !(options.body instanceof FormData)) {
    const body = JSON.stringify(
      toSnakeCase(JSON.parse(options.body as string))
    );

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
      afterResponse: [responseToCamelCase, ...(hooks?.afterResponse ?? [])],
      beforeRequest: [requestToSnakeCase, ...(hooks?.beforeRequest ?? [])],
      ...hooks,
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
  pathParams?: Record<string, unknown>
): string =>
  pathParams ?
    Object.entries(pathParams).reduce(
      (acc, [key, value]) => acc.replace(`:${key}`, value as string),
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
    pathParams?: Record<string, unknown>;
    searchParams?: Record<string, unknown>;
    useSnakeCase?: boolean;
  } = {}
): string => appendSearchParams(setPathParams(uri, pathParams), options);

export const getBaseUrl = (): string => {
  if (process.env.API_URL) {
    // server api call
    return process.env.API_URL;
  }

  if (typeof window !== 'undefined' && window.process.env.API_URL) {
    // client api call
    return window.process.env.API_URL;
  }

  // fallback
  return '';
};

/*
  Merges per-request auth/language onto any caller-supplied headers.
  Auth is threaded per request — never stored module-side — so a server
  process cannot leak one user's token into another user's request.
*/
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
