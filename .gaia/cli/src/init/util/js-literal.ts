/**
 * The sink-side half of `gaia init`'s `--title` policy, for the sinks that are
 * quoted JavaScript string literals.
 *
 * `./title.ts` refuses what is not a title and deliberately never rewrites the
 * value, because escaping is a property of the sink rather than of the input.
 * This is that escaping for one sink shape, shared by the two commands that
 * write a title into a `.ts` file: `init rename` (the seeded language files)
 * and `init strip-branding` (`.storybook/preview.ts`).
 */

/** The quote characters a value may be wrapped in. */
export type JsLiteralQuote = "'" | '"';

/**
 * `value` as it must appear between two `quote` characters in a JavaScript
 * string literal.
 *
 * Backslashes first, then the quote: escaping the quote introduces backslashes
 * of its own, and doubling those would emit a literal backslash in front of
 * the quote instead of escaping it.
 *
 * Only those two characters need it. A line ending is refused at the flag
 * boundary rather than escaped here, and U+2028 and U+2029 are legal in a
 * string literal from ES2019 on. The quote that is *not* wrapping the value
 * needs no escape and does not get one, so an apostrophe reaches a
 * double-quoted sink unchanged.
 *
 * `quote` is the two literal quotes and not `string`, because a backtick sink
 * would need `${` escaped as well and this escaping is wrong for one; a
 * template literal has to be handled where it is written, not admitted here.
 */
export const escapeJsLiteralValue = (
  value: string,
  quote: JsLiteralQuote
): string => value.replaceAll('\\', '\\\\').replaceAll(quote, `\\${quote}`);
