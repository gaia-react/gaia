/**
 * Shared argv primitives for the CLI's hand-rolled parsers.
 *
 * `lookupOwn` is the load-bearing one. A bare index into a `Record`-keyed table
 * resolves every `Object.prototype` member, so an argv token like `constructor`
 * or `__proto__` yields a truthy inherited value, survives the caller's
 * `=== undefined` check, and is then dispatched or consumed as though it named
 * a real entry.
 *
 * The two value readers differ only in whether a `--`-prefixed element counts
 * as a value. Both semantics are live, so each call site names the one it wants
 * rather than inheriting whichever was copied into it.
 */

/** The outcome of reading a `--flag`'s value out of argv. */
export type TakeValueResult =
  {message: string; ok: false} | {ok: true; value: string};

/** Reads `key` from `table` only when `table` owns it. */
export const lookupOwn = <TValue>(
  table: Readonly<Partial<Record<string, TValue>>>,
  key: string
): TValue | undefined => (Object.hasOwn(table, key) ? table[key] : undefined);

/** Reads the argv element at `index` as `flag`'s value. */
export const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): TakeValueResult => {
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

/** As `takeValue`, but treats a `--`-prefixed element as a missing value. */
export const takeNonFlagValue = (
  argv: readonly string[],
  index: number,
  flag: string
): TakeValueResult => {
  const value = argv.at(index);

  if (value === undefined || value.startsWith('--'))
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};
