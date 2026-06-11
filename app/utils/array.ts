// Throwaway no-op to trigger a CI audit run for breadcrumb verification. Revert.
export const range = (start: number, end: number): number[] => {
  if (start > end) return [];

  return (Array(end - start + 1) as number[])
    .fill(start)
    .map((value, index) => value + index);
};

export const uniqBy = <T, K extends keyof T>(
  array: T[],
  iteratee: (item: T) => T[K]
): T[] =>
  array.filter(
    (value, index, self) =>
      index === self.findIndex((other) => iteratee(other) === iteratee(value))
  );

type Comparable = bigint | boolean | Date | number | string;

// Keys of `T` whose values have a defined sort order. Sorting by any other
// key would silently compare to 0, so it is rejected at compile time.
type ComparableKey<T> = {
  [K in keyof T]: T[K] extends Comparable ? K : never;
}[keyof T];

export const sortBy = <T>(array: T[], key: ComparableKey<T>): T[] =>
  array.toSorted((a, b) => {
    const valueA = a[key];
    const valueB = b[key];

    return (
      valueA < valueB ? -1
      : valueA > valueB ? 1
      : 0
    );
  });
