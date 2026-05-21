// Based on proposed Safe Assignment Operator ?=
// https://github.com/arthurfiorette/proposal-try-operator/tree/old/proposal-safe-assignment-operator
type TryCatchError = [error: Error, result: undefined];
type TryCatchResult<T> =
  T extends Promise<unknown> ?
    Promise<TryCatchError | TryCatchSuccess<Awaited<T>>>
  : TryCatchError | TryCatchSuccess<T>;
type TryCatchSuccess<T> = [error: undefined, result: Awaited<T>];

export const tryCatch = <T, A extends readonly unknown[]>(
  fn: (...args: A) => T,
  ...args: A
): TryCatchResult<T> => {
  let error;
  let result;

  try {
    result = fn(...args);
  } catch (caughtError) {
    error = caughtError as Error;
  }

  if (result instanceof Promise) {
    return result
      .then((promiseResult: T) => [undefined, promiseResult])
      .catch((caughtError: Error) => [
        caughtError,
        undefined,
      ]) as TryCatchResult<T>;
  }

  if (error) {
    return [error, undefined] as TryCatchResult<T>;
  }

  return [undefined, result] as TryCatchResult<T>;
};

// eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
export const compose = (...fns: Function[]): Function =>
  // eslint-disable-next-line sonarjs/reduce-initial-value
  fns.reduce(
    (f, g) =>
      (...args: unknown[]) =>
        // eslint-disable-next-line @typescript-eslint/no-unsafe-return
        f(g(...args))
  );

export const noop = (): void => {};

export const sleep = async (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
