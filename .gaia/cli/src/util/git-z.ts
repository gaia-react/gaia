/**
 * The path-safe spelling this CLI builds its git *listing* commands from.
 *
 * Not every path it reads out of git comes through here: the
 * `status --porcelain` readers behind `porcelainZPaths` build their own argv,
 * and are safe without this because `-z` alone suffices for `status`, which
 * that docblock states as their half of the contract. So this is the one
 * spelling for the listing verbs rather than an assurance about every call.
 *
 * Under git's default `core.quotePath`, a path carrying a non-ASCII byte, a
 * control character, or a double quote comes back C-quoted:
 * `wiki/<CJK>.md` arrives as `"wiki/\346\227\245..."`. That spelling names no
 * file and no blob, and its leading double quote fails the `startsWith()`
 * prefix tests callers filter with. The defect that follows is a wrong answer
 * rather than an error, so a page that was never opened is reported exactly as
 * confidently as one that was.
 *
 * `-z` is the flag that does the work: it emits each path raw regardless of
 * that setting, and it delimits records with NUL, which also keeps a path
 * holding a literal newline as one record instead of two that name nothing.
 * `-c core.quotepath=false` is inert beside it, and is kept anyway so this
 * matches the spelling the repository's shell readers use for the same job.
 * The release workflow stages its tarball from one of them, and a listing that
 * reads differently here invites the conclusion that the two disagree.
 *
 * Both halves live here rather than at each call site because what has to be
 * made hard is omitting them. Every instance of this class was written from
 * muscle memory by an author who had no reason to suspect a plain listing
 * call was unsafe, and every one was caught by someone reading the code
 * rather than by anything that runs.
 */

/**
 * Argv for `git <verb>`, carrying the flags that keep paths readable.
 *
 * `-z` sits immediately after the verb, which every listing verb accepts
 * because git reads options in any order ahead of a command's operands. The
 * caller therefore appends its own arguments and never places the flag
 * itself, which is what leaves no position for it to be omitted from.
 */
export const gitZArgs = (
  verb: string,
  args: readonly string[] = []
): string[] => ['-c', 'core.quotepath=false', verb, '-z', ...args];

/**
 * The non-empty records of a NUL-delimited git stream.
 *
 * Filters rather than trims: `-z` delimits records exactly, so there is no
 * terminator left to strip, and trimming would instead eat leading or
 * trailing whitespace that git legally permits inside a path.
 */
export const splitZStream = (raw: string): string[] =>
  raw.split('\0').filter((record) => record.length > 0);
