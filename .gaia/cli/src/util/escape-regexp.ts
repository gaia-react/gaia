/**
 * Shared regex-literal escaper.
 *
 * One copy, because the escape set is a correctness boundary rather than a
 * formatting nicety. Most callers feed the result into `new RegExp(...)` built
 * from a token they did not choose, so a character class that is right in one
 * copy and stale in another silently changes which strings a guard matches.
 * That failure is invisible at the call site: the wrong pattern is still a
 * *valid* regex, it just matches (or refuses) a token its sibling handles the
 * other way.
 *
 * The release exclude path is the strictest caller, because one set of escaped
 * strings feeds two consumers that read them under different grammars:
 * `renderExcludeRegex` writes them to stdout for the shell staging pipeline to
 * read as POSIX ERE, and `parseExcludePatterns` compiles the same strings with
 * `new RegExp`. So the set has to satisfy both, and a JavaScript-only escape
 * added here (`/` as `\/`, a `\u{...}` form) breaks a parity contract the
 * compiling consumer cannot see.
 *
 * `escape-regexp.test.ts` beside this file is what pins the whole set
 * directly; every other caller is a guard that keeps passing its own suite
 * with a wrong set.
 */

// Hoisted rather than written inline: a literal in the function body
// constructs a fresh RegExp on every call. Sharing one `g`-flagged object
// across callers is safe because `replaceAll` resets `lastIndex` before it
// matches, so no call can observe another's scan position.
const METACHARACTERS = /[.*+?^${}()|[\]\\]/g;

/**
 * `value` with every regex metacharacter escaped, safe to interpolate into a
 * pattern as a literal.
 *
 * `*` is escaped along with the rest: a caller compiling a literal path would
 * otherwise have it silently rewritten into a glob. `[](){}^$|` are escaped
 * both to keep them literal and because leaving `[` unescaped opens a
 * character class the input never closes, which makes `new RegExp` throw
 * rather than mismatch.
 *
 * `-` is deliberately absent. It is a metacharacter only inside a character
 * class, and no caller interpolates into one; a caller that needs hyphen
 * adjacency handled bounds it with its own token boundaries instead.
 */
export const escapeRegExp = (value: string): string =>
  value.replaceAll(METACHARACTERS, String.raw`\$&`);
