/**
 * Shared `--flag <value>` argv walk for the `gaia update merge-*` oracles.
 *
 * Callers keep what differs: their own `Flags` type, their own flag-to-field
 * map, and their own validation of the collected record.
 */

/** Maps a `--flag` token to the state field its value is collected into. */
export type ValueFlagMap<TField extends string> = Readonly<
  Record<string, TField>
>;

type ApplyTokenArgs<TField extends string> = {
  argv: readonly string[];
  index: number;
  state: ValueFlagState<TField>;
  token: string;
  valueFlags: ValueFlagMap<TField>;
};

type TokenOutcome = {advance: number; ok: true} | {message: string; ok: false};

type ValueFlagResult<TField extends string> =
  {message: string; ok: false} | {ok: true; state: ValueFlagState<TField>};

type ValueFlagState<TField extends string> = {
  collected: Partial<Record<TField, string>>;
  json: boolean;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `.at()` (unlike bracket indexing) types its result `string | undefined`,
  // which honestly reflects that `index` can run past the end of argv.
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

// `token` may not be one of the map's known keys, and that absence is exactly
// what routes to the unknown-flag branch below. The own-property guard is
// load-bearing: a bare index reaches `Object.prototype`, so a token like
// `constructor` or `toString` returns a truthy inherited value, skips the
// unknown-flag branch, and consumes the following argv element as its value.
const lookupValueFlag = <TField extends string>(
  valueFlags: ValueFlagMap<TField>,
  token: string
): TField | undefined =>
  Object.hasOwn(valueFlags, token) ? valueFlags[token] : undefined;

const applyToken = <TField extends string>({
  argv,
  index,
  state,
  token,
  valueFlags,
}: ApplyTokenArgs<TField>): TokenOutcome => {
  if (token === '--json') {
    state.json = true;

    return {advance: 0, ok: true};
  }

  const field = lookupValueFlag(valueFlags, token);

  if (field === undefined)
    return {message: `unknown flag: ${token}`, ok: false};

  const taken = takeValue(argv, index + 1, token);

  if (!taken.ok) return taken;
  state.collected[field] = taken.value;

  return {advance: 1, ok: true};
};

/**
 * Walks `argv`, collecting each known `--flag <value>` pair into
 * `state.collected` and each `--json` into `state.json`, and stops at the
 * first unknown flag or value-less flag with that flag's message.
 *
 * Required-field validation is the caller's: this returns whatever the argv
 * happened to carry.
 */
export const parseValueFlags = <TField extends string>(
  argv: readonly string[],
  valueFlags: ValueFlagMap<TField>
): ValueFlagResult<TField> => {
  const state: ValueFlagState<TField> = {collected: {}, json: false};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== undefined) {
      const outcome = applyToken({argv, index, state, token, valueFlags});

      if (!outcome.ok) return outcome;
      index += outcome.advance;
    }
  }

  return {ok: true, state};
};
