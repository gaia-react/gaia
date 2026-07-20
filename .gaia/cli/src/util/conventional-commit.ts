/**
 * The conventional-commit header grammar and the repo's permitted commit-type
 * vocabulary, declared once for every consumer.
 *
 * Three modules read commit subjects and disagree about nothing else:
 * `release/bump.ts` picks a semver bump, `release/changelog.ts` picks a
 * CHANGELOG section, and `wiki/commit-classify.ts` picks WORTHY or SKIP. Each
 * used to carry a private copy of the same regex, and the copies had already
 * drifted apart on what they captured, which is how the breaking-marker
 * reading came to differ between the release bump and the wiki classifier.
 *
 * Consumers keep their own disposition logic; only the grammar and the type
 * vocabulary live here. Each disposition table is a `Record<CommitType, ...>`,
 * so adding a type below is a compile error in every consumer until each one
 * says what to do with it. That is the point: an undeclared type used to be
 * invisible until a release produced no bump or a sync deep-read everything.
 */

/**
 * Every commit type the repo permits. Adding one here forces a decision in
 * `release/bump.ts` (bump kind), `release/changelog.ts` (section), and the
 * `wiki/commit-classify.ts` rule table (which a test asserts reaches a rule
 * rather than the fail-open default).
 */
export const COMMIT_TYPES = [
  'build',
  'chore',
  'ci',
  'debt',
  'docs',
  'feat',
  'fix',
  'perf',
  'refactor',
  'revert',
  'style',
  'test',
  'wiki',
] as const;

export type CommitType = (typeof COMMIT_TYPES)[number];

export type ConventionalCommitHeader = {
  /** True when the subject carries a `!` marker, on any type. */
  breaking: boolean;
  /** The message after the `:`, trimmed. Empty when the subject is header-only. */
  rest: string;
  /** The `(scope)` contents, or `undefined` when no scope is present. */
  scope: string | undefined;
  /** The raw type. Not necessarily a declared `CommitType`; see `isCommitType`. */
  type: string;
};

// A type, an optional `(scope)`, an optional `!` breaking marker, then `:`.
// `breaking` is written `(?<breaking>!?)` rather than as an optional group so
// it always participates and captures `''` or `'!'`: `noUncheckedIndexedAccess`
// is off, so an optional group's `undefined` is invisible to the type checker
// and a `!== undefined` test would be statically meaningless.
const HEADER_PATTERN =
  /^(?<type>[a-z]+)(?:\((?<scope>[^)]*)\))?(?<breaking>!?):/u;

/**
 * Parse a commit subject's conventional-commit header, or `undefined` when the
 * subject does not carry one.
 *
 * `rest` is derived by slicing off the matched header rather than by extending
 * the pattern with `(?<rest>.*)$`, so a subject that somehow carries a newline
 * still parses instead of silently failing to match.
 */
export const parseConventionalCommitHeader = (
  subject: string
): ConventionalCommitHeader | undefined => {
  const trimmed = subject.trim();
  const match = HEADER_PATTERN.exec(trimmed);

  if (match?.groups === undefined) return undefined;

  const {breaking, scope, type} = match.groups;

  return {
    breaking: breaking === '!',
    rest: trimmed.slice(match[0].length).trim(),
    scope,
    type,
  };
};

/** Narrow a parsed type to the declared vocabulary. */
export const isCommitType = (type: string): type is CommitType =>
  (COMMIT_TYPES as readonly string[]).includes(type);
