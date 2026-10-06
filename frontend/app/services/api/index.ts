import ky from 'ky';
import type {Options, StandardSchemaV1, StandardSchemaV1InferOutput} from 'ky';
import type {StringifyOptions} from 'query-string';
import {buildRequestHeaders, getBaseUrl, getHooks, getUri} from './utils';

export type RequestFunction = {
  <S extends StandardSchemaV1>(
    uri: string,
    options: RequestOptions & {schema: S}
  ): Promise<StandardSchemaV1InferOutput<S>>;
  (uri: string, options?: RequestOptions & {schema?: undefined}): Promise<void>;
};

type CreateOptions = Omit<Options, 'prefix'> & {
  arrayFormat?: NonNullable<StringifyOptions['arrayFormat']>;
  /** Base URL; resolved per request from getBaseUrl() when omitted. */
  prefix?: string;
  /**
   * Converts incoming response keys to camelCase and outgoing JSON bodies and
   * search params to snake_case. Defaults to true; pass false when the API
   * already speaks camelCase.
   */
  useSnakeCase?: boolean;
};

type RequestOptions = Options & {
  language?: string;
  pathParams?: Record<string, number | string>;
  searchParams?: Record<string, unknown>;
  token?: string;
};

export const create = ({
  arrayFormat = 'comma',
  hooks,
  prefix,
  useSnakeCase = true,
  ...apiOptions
}: CreateOptions = {}): RequestFunction => {
  const kyInstance = ky.create({
    hooks: getHooks(useSnakeCase, hooks),
    ...apiOptions,
  });

  const request = async (
    uri: string,
    {
      language,
      pathParams,
      schema,
      searchParams,
      token,
      ...options
    }: RequestOptions & {schema?: StandardSchemaV1} = {}
  ): Promise<unknown> => {
    const response = kyInstance(
      getUri(uri, {arrayFormat, pathParams, searchParams, useSnakeCase}),
      {
        ...options,
        headers: buildRequestHeaders(options.headers, token, language),
        // Resolved per request: the base URL is unknown at module import.
        prefix: prefix ?? (getBaseUrl() || '/'),
      }
    );

    if (schema) {
      return response.json(schema);
    }

    await response;
  };

  return request as RequestFunction;
};
