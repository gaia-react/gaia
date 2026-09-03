/**
 * The shared `gaia <command>` invocation matcher for the maintainer CLI guards.
 *
 * Two guards ask whether a command is invoked in some text, from opposite
 * directions, and both need the same answer:
 *
 *   * `command-reachability.test.ts` asks whether *any* invoker exists for a
 *     leaf command, so a command nobody calls fails there.
 *   * `automation/__tests__/gaia-ci-template-refs.test.ts` asks whether the
 *     invocation a `gaia-ci-*` template's contract declares still appears in
 *     that template, so a silent drop fails there.
 *
 * `#1037` taught the first guard to read a quoted binary path. `#1271` found
 * the second still deciding the same question with a bare `includes('gaia ' +
 * command)` substring test, which cannot see that form, and extracted the
 * matcher here rather than copying it into a second file: a hand-copied second
 * regex is the class `#1720` drained, and the two guards diverging on what
 * counts as an invocation is precisely the failure `#1271` recorded.
 *
 * Test-only, though nothing here is test-specific: both consumers are
 * `.test.ts` files, so this module is unreachable from `src/index.ts` and none
 * of it enters the bundled binary. It is not named `*-fixture.ts` for that
 * reason. The three that are (`repo-root-fixture.ts`,
 * `non-ascii-path-fixture.ts`, `main-checkout-fixture.ts`) supply values or
 * environment to other suites and have no behavior of their own to assert;
 * this is a matcher with its own test beside it, and naming it for what it is
 * keeps that suffix meaning the one thing it means.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither this module nor its consumers.
 */

const escapeRegExp = (value: string): string =>
  value.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

// An invocation-shaped string for `commandPath` in `text`: the binary name,
// optionally closed by a quote, then the space-separated path, bounded so
// `wiki state` never matches inside `wiki state-bump`.
//
// The quote class is what lets a **release-resolved** invocation count. A
// subcommand invoked only as `"$LATEST_DIR/.gaia/cli/gaia" update merge-region`
// puts a closing quote exactly where the separator is required, so without the
// class the guard reads a live command as dead and the author has to mention
// its bare form somewhere else to clear a red. Note the narrower fix does not
// exist: an *unquoted* path prefix already matched, because `/` is neither
// `\w` nor `-`, so the quote is the whole of the blind spot.
//
// The quote is admitted beside the separator and never instead of it, so a
// bare path with no separator at all stays excluded.
// `.gaia/tests/distribution/17-gaia-update-merge-region.sh` reached the same
// `gaia"?` shape for the same reason.
//
// Takes its haystack as an argument rather than closing over a guard's own
// corpus, so the pattern itself can be exercised against fixture strings.
// Reading the oracle only through the whole repository's text cannot show the
// difference between "this form is unmatchable" and "no such invocation exists
// here".
//
// Both classes are parameters for the same reason: each consumer needs a
// different value, and a hand-copied second regex would drift from this one
// silently. `binaryClass` is which binaries count (see the exports below, which
// is where the choice is argued); `quoteClass` exists so the pre-widening shape
// stays available as a control. Only the three exported matchers pass either
// one, and each pins both values.
const invocationPattern = (
  commandPath: string,
  binaryClass: string,
  quoteClass: string
): RegExp => {
  const tokens = commandPath
    .split(' ')
    .map(escapeRegExp)
    .join(String.raw`\s+`);

  return new RegExp(
    String.raw`(?<![\w-])${binaryClass}${quoteClass}\s+${tokens}(?![\w-])`
  );
};

// Either binary. The reachability guard enumerates leaf commands from both
// entrypoints, and a maintainer-only command's only legitimate invocation is
// `gaia-maintainer <path>`, so pinning the adopter binary there would read
// every maintainer command as dead.
const EITHER_BINARY = 'gaia(?:-maintainer)?';

// The adopter binary alone. `gaia-maintainer` is excluded from the adopter
// tarball, so an invocation through it is unrunnable on an adopter clone and
// must not satisfy a contract that promises the command is reachable there.
const SHIPPED_BINARY = 'gaia';

/**
 * Whether `text` invokes `commandPath` through either binary, bare or through
 * a quoted path.
 */
export const matchesInvocation = (commandPath: string, text: string): boolean =>
  invocationPattern(commandPath, EITHER_BINARY, '["\']?').test(text);

/**
 * Whether `text` invokes `commandPath` through the binary adopters actually
 * receive, bare or through a quoted path.
 */
export const matchesShippedInvocation = (
  commandPath: string,
  text: string
): boolean =>
  invocationPattern(commandPath, SHIPPED_BINARY, '["\']?').test(text);

// The either-binary matcher without the quote class, i.e. the shape that could
// not see a release-resolved invocation. Used only as a control, in this
// module's own test and in the reachability guard's skills-surface test, where
// the haystack is a real corpus that may also carry a bare form; never as an
// oracle.
export const matchesUnquotedInvocation = (
  commandPath: string,
  text: string
): boolean => invocationPattern(commandPath, EITHER_BINARY, '').test(text);
