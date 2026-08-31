/**
 * Shared fixture values for the suites that prove a git path listing survives
 * a name git would otherwise rewrite on the way out.
 *
 * Each value below is a decision rather than an arbitrary constant, and each
 * decision was previously restated at every suite that made it. They are
 * stated once here so a later reader finds the reasoning rather than a literal
 * whose point has to be reconstructed.
 */

/**
 * The stem a C-quoting canary fixture is named with.
 *
 * CJK, deliberately: it has no NFD decomposition, so macOS filesystem
 * normalization cannot round-trip the name into a spelling the code under test
 * accepts by accident. An accented Latin stem can, which would make a canary
 * pass for a reason that has nothing to do with the flags it is guarding.
 */
export const NON_ASCII_STEM = '日本語';

/**
 * The leading octal escape of `NON_ASCII_STEM`'s C-quoted spelling.
 *
 * A canary asserts a listing contains this, and does not contain the raw stem,
 * before the test beside it asserts anything about the code under test. A
 * fixture that is not in fact being quoted makes that second test vacuously
 * green, which is the outcome a canary exists to rule out.
 */
export const QUOTED_FIRST_BYTE = String.raw`\346`;

/**
 * `git config` argv pinning C-quoting on in a fixture repository.
 *
 * This is git's own default, set explicitly all the same. A developer whose
 * global config carries `core.quotepath=false` would otherwise strip the very
 * quoting these fixtures exist to defeat, and every canary would pass on the
 * one machine where the code under test was never exercised.
 */
export const QUOTEPATH_PIN_ARGS: readonly string[] = [
  'config',
  'core.quotepath',
  'true',
];
