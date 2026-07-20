/**
 * `gaia ci-check-subject --subject "<text>"` handler.
 *
 * Validates one commit subject against the declared conventional-commit
 * grammar and type vocabulary in `util/conventional-commit.ts`.
 *
 * Aimed at PR titles specifically. Merges here are squash-merges, so the PR
 * title becomes the commit subject on `main` and is therefore what the release
 * bump, the CHANGELOG draft, and the wiki classifier all read; the branch
 * commits are discarded. That makes the title the one point where validating
 * is both load-bearing and cheap.
 *
 * Deliberately not a per-commit lint. Branch commits are overwhelmingly
 * conforming already, and a per-commit gate would add friction defending
 * something that is not breaking.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  COMMIT_TYPES,
  isCommitType,
  parseConventionalCommitHeader,
} from '../util/conventional-commit.js';

const HELP_TEXT = `Usage: gaia ci-check-subject --subject "<text>"

  Validate a commit subject (in practice a squash-merge PR title) against
  the conventional-commit grammar and the declared type vocabulary.

  Exit codes:
    0  valid
    1  invalid, or bad arguments
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubjectCheck = {message: string; ok: false} | {ok: true; type: string};

/**
 * Validate a subject. Failures name the declared vocabulary, since the whole
 * point is that the permitted set is discoverable rather than implied by
 * whatever the tooling happens to test for.
 */
export const checkSubject = (subject: string): SubjectCheck => {
  const header = parseConventionalCommitHeader(subject);

  if (header === undefined) {
    return {
      message:
        `"${subject}" is not a conventional-commit subject. ` +
        'Expected "<type>(<optional scope>): <description>", ' +
        `where <type> is one of: ${COMMIT_TYPES.join(', ')}.`,
      ok: false,
    };
  }

  if (!isCommitType(header.type)) {
    return {
      message:
        `"${header.type}" is not a declared commit type. ` +
        `Expected one of: ${COMMIT_TYPES.join(', ')}. ` +
        'Add it to COMMIT_TYPES in .gaia/cli/src/util/conventional-commit.ts ' +
        'if it should be, which forces a release-bump, CHANGELOG, and wiki ' +
        'disposition for it.',
      ok: false,
    };
  }

  if (header.rest.length === 0) {
    return {
      message: `"${subject}" has a valid type but no description after the colon.`,
      ok: false,
    };
  }

  return {ok: true, type: header.type};
};

const parseFlags = (
  argv: readonly string[]
): {message: string; ok: false} | {ok: true; subject: string} => {
  let subject: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--subject') {
      if (index + 1 >= argv.length) {
        return {message: '--subject requires a value', ok: false};
      }
      subject = argv[index + 1];
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  if (subject === undefined) {
    return {message: '--subject <text> is required', ok: false};
  }

  return {ok: true, subject};
};

export const run = (argv: readonly string[]): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'ci-check-subject',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const checked = checkSubject(parsed.subject);

  if (!checked.ok) {
    structuredError({
      code: 'invalid_subject',
      message: checked.message,
      subcommand: 'ci-check-subject',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  process.stdout.write(`${checked.type}\n`);

  return EXIT_CODES.OK;
};
