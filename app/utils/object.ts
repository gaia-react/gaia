import {camelCase, snakeCase} from 'lodash-es';
import SparkMD5 from 'spark-md5';

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/*
  Generates an MD5 hash for a given input object
  It is most commonly used for creating unique keys for React components
*/
export const md5 = (obj: Record<string, unknown>): string =>
  SparkMD5.hash(JSON.stringify(obj));

/*
  Checks if all values in an object satisfy a given predicate function
 */
export const every = (
  obj: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => {
  const values = Object.values(obj);

  return values.length > 0 && values.every(predicate);
};

/*
  Checks if at least one value in an object satisfies a given predicate function
 */
export const some = (
  obj: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => Object.values(obj).some(predicate);

/*
  Utility function to check if a value is null or undefined
 */
export const isNil = (value: unknown): boolean =>
  value === null || value === undefined;

/*
  Recursively removes all null and undefined values from an object or array
 */
export const deepRemoveNil = (input: unknown): unknown => {
  if (isNil(input)) {
    return;
  }

  if (Array.isArray(input)) {
    return input.reduce<unknown[]>((accumulated, value) => {
      if (!isNil(value)) {
        accumulated.push(deepRemoveNil(value));
      }

      return accumulated;
    }, []);
  }

  if (isObject(input)) {
    return Object.entries(input).reduce<Record<string, unknown>>(
      (accumulated, [key, value]) => {
        if (!isNil(value)) {
          accumulated[key] = deepRemoveNil(value);
        }

        return accumulated;
      },
      {}
    );
  }

  return input;
};

/*
  Transforms the keys of an object using a provided function
 */
export const mapKeys = (
  obj: Record<string, unknown>,
  fn: (key: string) => string
): Record<string, unknown> =>
  Object.entries(obj).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      accumulated[fn(key)] = value;

      return accumulated;
    },
    {}
  );

/*
  Transforms the values of an object using a provided function
 */
export const mapValues = (
  obj: Record<string, unknown>,
  fn: (value: unknown) => unknown
): Record<string, unknown> =>
  Object.entries(obj).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      accumulated[key] = fn(value);

      return accumulated;
    },
    {}
  );

/*
  Case Conversion Utilities
 */
export const convertCase = (
  fn: (text: string) => string,
  obj: unknown
): unknown => {
  if (obj === undefined) {
    return;
  }

  if (Array.isArray(obj)) {
    return obj.map((value: unknown) => convertCase(fn, value));
  }

  if (isObject(obj)) {
    return Object.entries(obj).reduce(
      (accumulated: Record<string, unknown>, [key, value]) => {
        if (Array.isArray(value)) {
          accumulated[fn(key)] = value.map<unknown>((item) =>
            isObject(item) ? convertCase(fn, item) : item
          );
        } else if (isObject(value)) {
          accumulated[fn(key)] = convertCase(fn, value);
        } else {
          accumulated[fn(key)] = value;
        }

        return accumulated;
      },
      {}
    );
  }

  return obj;
};

/*
  Converts the keys of an object to snake_case
 */
export const toSnakeCase = <T = unknown>(obj: unknown): T | undefined =>
  obj ? (convertCase(snakeCase, obj) as T) : undefined;

/*
  Converts the keys of an object to camelCase
 */
export const toCamelCase = <T = unknown>(obj: unknown): T | undefined =>
  obj ? (convertCase(camelCase, obj) as T) : undefined;

/*
  Removes nil, falsy, or empty array values from an object based on options
 */
export const compact = (
  obj: Record<string, unknown>,
  options?: {keepEmptyArray?: boolean; keepFalsy?: boolean}
): Record<string, unknown> =>
  Object.entries(obj).reduce<Record<string, unknown>>(
    (accumulated, [key, value]) => {
      if (
        ((options?.keepFalsy && !isNil(value)) || value) &&
        (!Array.isArray(value) || options?.keepEmptyArray || value.length > 0)
      ) {
        accumulated[key] = value;
      }

      return accumulated;
    },
    {}
  );
