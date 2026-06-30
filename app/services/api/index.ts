import ky from 'ky';
import type {Options} from 'ky';
import type {StringifyOptions} from 'query-string';
import {buildRequestHeaders, getBaseUrl, getHooks, getUri} from './utils';

type CreateOptions = Options & {
  arrayFormat?: NonNullable<StringifyOptions['arrayFormat']>;
  useSnakeCase?: boolean;
};

type RequestOptions = Options & {
  language?: string;
  pathParams?: Record<string, number | string>;
  searchParams?: Record<string, unknown>;
  token?: string;
};

export const create = <ApiResponseType>({
  arrayFormat = 'comma',
  hooks,
  prefix = getBaseUrl(),
  useSnakeCase = true,
  ...apiOptions
}: CreateOptions = {}) => {
  const kyInstance = ky.create({
    hooks: getHooks(useSnakeCase, hooks),
    prefix,
    ...apiOptions,
  });

  return async (
    uri: string,
    {language, pathParams, searchParams, token, ...options}: RequestOptions = {}
  ): Promise<ApiResponseType> =>
    kyInstance<ApiResponseType>(
      getUri(uri, {arrayFormat, pathParams, searchParams, useSnakeCase}),
      {
        ...options,
        headers: buildRequestHeaders(options.headers, token, language),
      }
    ).json();
};
