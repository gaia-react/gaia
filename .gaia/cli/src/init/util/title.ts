/**
 * The shapes `gaia init`'s `--title` may not take.
 *
 * Shared by `init rename` and `init strip-branding`, which take the same value
 * from the same source: `/gaia-init` collects the project title once and passes
 * it to both. One checker is what keeps the rule from being stated correctly on
 * one command and wrongly on the other.
 *
 * The policy is refuse-or-escape, split by what the value is:
 *
 *   - **Refuse here** what is not a title at all. A line ending and a blank
 *     have no faithful rendering in any sink, so no escaping saves them, and
 *     refusing ahead of the first write leaves a rejected run having changed
 *     nothing.
 *   - **Escape at the sink** what is an ordinary title character. `Steve's App`
 *     and `Q1 $1 Report` are titles, and each sink escapes them its own way: a
 *     single-quoted JavaScript literal, a markdown heading, a JSON string, a
 *     `String.replace` replacement. A single canonical escape here would be
 *     wrong for at least one of them, so this checker never rewrites the value.
 */

/**
 * The message describing why `title` is unusable, or `undefined` when it is.
 *
 * Returns a message rather than a caller's result type: each command wraps it
 * in its own parse-failure shape.
 */
export const titleFailure = (title: string): string | undefined => {
  // A line ending splits a one-line value in two. In `rename` it splits the
  // `CLAUDE.md` heading, whose idempotency guard then compares only the first
  // line and re-appends on every run; in `strip-branding` it emits an
  // unterminated string literal in `.storybook/preview.ts`, so Storybook
  // cannot build in a freshly scaffolded project.
  if (/[\n\r]/u.test(title)) {
    return '--title must be a single line';
  }

  // A blank title writes a heading with nothing under it: `# ` in `CLAUDE.md`
  // via `rename`, and the same `# ` in the generated README via
  // `strip-branding`, whose template's first line is `# {{PROJECT_TITLE}}`.
  // That is the state `claudeMdPreconditionMet` refuses when the file arrives
  // carrying it, reached through the flag instead.
  if (title.trim() === '') {
    return '--title must not be blank';
  }

  return undefined;
};
