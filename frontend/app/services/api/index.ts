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
  /**
   * Converts incoming response keys to camelCase and outgoing JSON bodies and
   * search params to snake_case, for an API that speaks snake_case.
   */
  isSnakeCaseEnabled?: boolean;
  /** Base URL; resolved per request from getBaseUrl() when omitted. */
  prefix?: string;
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
  isSnakeCaseEnabled = false,
  prefix,
  ...apiOptions
}: CreateOptions = {}): RequestFunction => {
  const kyInstance = ky.create({
    hooks: getHooks(isSnakeCaseEnabled, hooks),
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
      getUri(uri, {
        arrayFormat,
        isSnakeCaseEnabled,
        pathParams,
        searchParams,
      }),
      {
        ...options,
        headers: buildRequestHeaders(options.headers, token, language),
        // Resolved per request: the base URL is unknown at module import.
        prefix: options.prefix ?? prefix ?? (getBaseUrl() || '/'),
      }
    );

    if (schema) {
      return response.json(schema);
    }

    // Read the body even though it is discarded: on Node, an unread body keeps
    // its connection out of the keep-alive pool until garbage collection.
    const discardedResponse = await response;
    await discardedResponse.arrayBuffer();
  };

  return request as RequestFunction;
};
