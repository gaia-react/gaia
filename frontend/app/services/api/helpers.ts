import {HTTPError, SchemaValidationError} from 'ky';
import {ZodError} from 'zod';
import {tryCatch} from '~/utils/function';

type ApiError = {status: number; statusText: string};

const isHTTPError = (error: unknown): error is HTTPError =>
  error instanceof HTTPError;

const handleHTTPError = (error: HTTPError): ApiError => ({
  status: error.response.status,
  statusText: error.response.statusText,
});

const isSchemaValidationError = (
  error: unknown
): error is SchemaValidationError => error instanceof SchemaValidationError;

// The issues can echo response data, so they are logged on the server only
// and never placed in statusText, which reaches the client.
const handleSchemaValidationError = (
  error: SchemaValidationError
): ApiError => {
  if (typeof window === 'undefined') {
    // eslint-disable-next-line no-console
    console.error('Response failed schema validation', error.issues);
  }

  return {status: 500, statusText: 'Response failed schema validation'};
};

const isZodError = (error: unknown): error is ZodError =>
  error instanceof ZodError;

const handleZodError = (error: ZodError): ApiError => ({
  status: 500,
  statusText: error.message,
});

const handleResponseError = (error: unknown): ApiError => {
  if (isHTTPError(error)) {
    return handleHTTPError(error);
  }

  if (isSchemaValidationError(error)) {
    return handleSchemaValidationError(error);
  }

  if (isZodError(error)) {
    return handleZodError(error);
  }

  if (error instanceof Error) {
    throw error;
  }

  return {status: 500, statusText: 'Unknown error'};
};

type AttemptError = [error: ApiError, result: undefined];
type AttemptResult<T> = AttemptError | AttemptSuccess<T>;
type AttemptSuccess<T> = [error: undefined, result: T];

export const attempt = async <T>(
  fn: () => Promise<T>
): Promise<AttemptResult<T>> => {
  const [error, result] = await tryCatch(fn);

  if (error) {
    return [handleResponseError(error), undefined];
  }

  return [undefined, result];
};
