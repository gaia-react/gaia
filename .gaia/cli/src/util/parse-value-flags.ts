/**
 * Shared `--flag <value>` argv walk for the `gaia update merge-*` oracles.
 *
 * Callers keep what differs: their own `Flags` type, their own flag-to-field
 * map, and their own validation of the collected record.
 */
import {lookupOwn, takeValue} from './argv.js';

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

  const field = lookupOwn(valueFlags, token);

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
