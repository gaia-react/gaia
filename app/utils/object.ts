import {camelCase, snakeCase} from 'lodash-es';
import SparkMD5 from 'spark-md5';

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

export const md5 = (obj: Record<string, unknown>): string =>
  SparkMD5.hash(JSON.stringify(obj));

export const every = (
  obj: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => {
  const values = Object.values(obj);

  return values.length > 0 && values.every(predicate);
};

export const some = (
  obj: Record<string, unknown>,
  predicate: (value: unknown) => boolean
): boolean => Object.values(obj).some(predicate);

export const isNil = (value: unknown): boolean =>
  value === null || value === undefined;

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

export const toSnakeCase = <T = unknown>(obj: unknown): T | undefined =>
  obj ? (convertCase(snakeCase, obj) as T) : undefined;

export const toCamelCase = <T = unknown>(obj: unknown): T | undefined =>
  obj ? (convertCase(camelCase, obj) as T) : undefined;

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
