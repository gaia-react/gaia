/**
 * `gaia wiki commit-classify --since <sha> [--json]` handler.
 *
 * Walks every commit in `<since>..HEAD` and emits a deterministic
 * WORTHY/SKIP suggestion plus the rule that fired. Replaces the
 * subject-only first pass in `wiki/sync.md` Step 3.
 *
 * Rule precedence (first match wins). Mirrors the rules in
 * `wiki/sync.md` Step 3 and the README "Wiki primitives JSON schemas"
 * contract:
 *
 *   1. `Merge pull request`, `wiki:` (sync's own commits), `chore(release):`,
 *      `style:` — SKIP regardless.
 *   2. Body contains `BREAKING CHANGE` OR subject is `feat!:` OR
 *      `docs(decision):` OR `chore(adr):` — WORTHY.
 *   3. Touches `wiki/decisions/`, `wiki/concepts/`, `wiki/flows/`,
 *      `wiki/dependencies/`, or `wiki/entities/` — WORTHY.
 *   4. Touches `app/middleware/**`, `app/routes.ts`, `app/i18n.ts`, or
 *      `app/sessions.server/**` — WORTHY (flows-relevant).
 *   5. `chore(deps):`, `chore(cli):`, `wiki:` — SKIP unless body mentions
 *      `architecture` or trade-off / invariant / gotcha keywords.
 *   6. `feat:` / `fix:` / `refactor:` touching `app/**` non-test files —
 *      WORTHY.
 *   7. `feat:` / `fix:` / `refactor:` touching only test files OR
 *      pages/components/hooks/services without body decision keywords —
 *      SKIP (Serena handles inventory).
 *   8. `chore:`, `docs:`, `test:` (without earlier override) — SKIP.
 *   9. Anything else — WORTHY (false positive better than false negative).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {commitDetails, resolveRepoRoot, type CommitDetail} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki commit-classify --since <sha> [--json]

  Emit a deterministic WORTHY/SKIP suggestion for every commit in
  <sha>..HEAD. Without --json, prints a tabular summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type CommitSuggestion = 'SKIP' | 'WORTHY';

export type ClassifiedCommit = {
  body: string;
  deletions: number;
  files_changed: number;
  insertions: number;
  sha: string;
  subject: string;
  suggestion: CommitSuggestion;
  suggestion_reason: string;
};

export type CommitClassification = {
  commits: ClassifiedCommit[];
};

type FlagParseSuccess = {
  flags: {json: boolean; since: string};
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined) return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (
  argv: readonly string[]
): FlagParseFailure | FlagParseSuccess => {
  let since: string | undefined;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--since') {
      const taken = takeValue(argv, index + 1, '--since');

      if (!taken.ok) return taken;
      since = taken.value;
      index += 1;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (since === undefined) {
    return {message: '--since <sha> is required', ok: false};
  }

  return {flags: {json, since}, ok: true};
};

const ARCH_BODY_PATTERN =
  /BREAKING CHANGE|architecture|trade-?off|invariant|gotcha|workaround|decision/iu;

const WIKI_HEAVY_DOMAINS = [
  'wiki/decisions/',
  'wiki/concepts/',
  'wiki/flows/',
  'wiki/dependencies/',
  'wiki/entities/',
];

const FLOWS_RELEVANT_PATHS = [
  'app/middleware/',
  'app/routes.ts',
  'app/i18n.ts',
  'app/sessions.server/',
];

const APP_INVENTORY_PREFIXES = [
  'app/components/',
  'app/hooks/',
  'app/services/',
  'app/pages/',
];

const touchesAny = (files: readonly string[], prefixes: readonly string[]): boolean =>
  files.some((file) => prefixes.some((prefix) => file.startsWith(prefix)));

const touchesAppNonTest = (files: readonly string[]): boolean =>
  files.some((file) => file.startsWith('app/') && !file.includes('.test.'));

const touchesOnlyTests = (files: readonly string[]): boolean =>
  files.length > 0 && files.every((file) => file.includes('.test.'));

const classify = (
  commit: CommitDetail
): {reason: string; suggestion: CommitSuggestion} => {
  const subject = commit.subject;
  const body = commit.body;
  const files = commit.files;

  // 1. Hard-skip prefixes.
  if (subject.startsWith('Merge pull request')) {
    return {reason: 'merge commit', suggestion: 'SKIP'};
  }

  if (subject.startsWith('chore(release):')) {
    return {reason: 'chore(release): release plumbing', suggestion: 'SKIP'};
  }

  if (subject.startsWith('style:')) {
    return {reason: 'style: formatting only', suggestion: 'SKIP'};
  }

  // 2. Strong WORTHY signals.
  if (subject.startsWith('feat!:') || /BREAKING CHANGE/u.test(body)) {
    return {reason: 'breaking change signal', suggestion: 'WORTHY'};
  }

  if (subject.startsWith('docs(decision):') || subject.startsWith('chore(adr):')) {
    return {reason: 'explicit ADR signal', suggestion: 'WORTHY'};
  }

  // 3. Touches a wiki-heavy domain.
  if (touchesAny(files, WIKI_HEAVY_DOMAINS)) {
    return {reason: 'touches wiki-heavy domain', suggestion: 'WORTHY'};
  }

  // 4. Flows-relevant app paths.
  if (touchesAny(files, FLOWS_RELEVANT_PATHS)) {
    return {reason: 'touches flows-relevant path', suggestion: 'WORTHY'};
  }

  // 5. Architecture-suppressible chore prefixes.
  if (subject.startsWith('chore(deps):')) {
    if (ARCH_BODY_PATTERN.test(body)) {
      return {
        reason: 'chore(deps): body mentions architecture / decision',
        suggestion: 'WORTHY',
      };
    }

    return {reason: 'chore(deps): version bump only', suggestion: 'SKIP'};
  }

  if (subject.startsWith('chore(cli):')) {
    if (ARCH_BODY_PATTERN.test(body)) {
      return {
        reason: 'chore(cli): body mentions architecture / decision',
        suggestion: 'WORTHY',
      };
    }

    return {reason: 'chore(cli): tooling-internal', suggestion: 'SKIP'};
  }

  if (subject.startsWith('wiki:')) {
    if (ARCH_BODY_PATTERN.test(body)) {
      return {reason: 'wiki: body mentions architecture', suggestion: 'WORTHY'};
    }

    return {reason: 'wiki: self-referential', suggestion: 'SKIP'};
  }

  // 6/7. feat/fix/refactor — app/** non-test → WORTHY; tests-only or
  // app inventory paths without decision keywords → SKIP.
  const isFeatureCommit =
    subject.startsWith('feat:') ||
    subject.startsWith('fix:') ||
    subject.startsWith('refactor:');

  if (isFeatureCommit) {
    if (touchesOnlyTests(files)) {
      return {
        reason: 'feat/fix/refactor: tests-only',
        suggestion: 'SKIP',
      };
    }

    const onlyInventory =
      files.length > 0 && files.every((file) => APP_INVENTORY_PREFIXES.some((prefix) => file.startsWith(prefix)));

    if (onlyInventory && !ARCH_BODY_PATTERN.test(body)) {
      return {
        reason:
          'feat/fix/refactor: only inventory paths (Serena handles inventory)',
        suggestion: 'SKIP',
      };
    }

    if (touchesAppNonTest(files)) {
      return {
        reason: 'feat/fix/refactor: app/** non-test',
        suggestion: 'WORTHY',
      };
    }

    return {
      reason: 'feat/fix/refactor: defer to human review',
      suggestion: 'WORTHY',
    };
  }

  // 8. Catch-all chore / docs / test prefixes.
  if (subject.startsWith('chore:')) {
    if (ARCH_BODY_PATTERN.test(body)) {
      return {reason: 'chore: body mentions architecture', suggestion: 'WORTHY'};
    }

    return {reason: 'chore: generic chore', suggestion: 'SKIP'};
  }

  if (subject.startsWith('docs:')) {
    return {reason: 'docs: prose-only', suggestion: 'SKIP'};
  }

  if (subject.startsWith('test:')) {
    return {reason: 'test: test-only change', suggestion: 'SKIP'};
  }

  // 9. Default: defer to human review.
  return {
    reason: 'no matching prefix — defer to human review',
    suggestion: 'WORTHY',
  };
};

const printHuman = (classification: CommitClassification): void => {
  if (classification.commits.length === 0) {
    process.stdout.write('No commits to classify.\n');

    return;
  }

  const lines = [`Classified ${classification.commits.length} commit(s):`, ''];

  for (const commit of classification.commits) {
    lines.push(
      `  ${commit.sha.slice(0, 7)}  ${commit.suggestion.padEnd(7)}  ${commit.subject}`
    );
    lines.push(`            reason: ${commit.suggestion_reason}`);
    lines.push(
      `            ${commit.files_changed} files, +${commit.insertions} -${commit.deletions}`
    );
  }
  process.stdout.write(`${lines.join('\n')}\n`);
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki commit-classify',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki commit-classify must run inside a git repository',
      subcommand: 'wiki commit-classify',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let details: CommitDetail[];

  try {
    details = commitDetails(parsed.flags.since, repoRoot);
  } catch (error) {
    structuredError({
      code: 'git_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki commit-classify',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const classification: CommitClassification = {
    commits: details.map((detail) => {
      const decision = classify(detail);

      return {
        body: detail.body,
        deletions: detail.deletions,
        files_changed: detail.files_changed,
        insertions: detail.insertions,
        sha: detail.sha,
        subject: detail.subject,
        suggestion: decision.suggestion,
        suggestion_reason: decision.reason,
      };
    }),
  };

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(classification)}\n`);
  } else {
    printHuman(classification);
  }

  return EXIT_CODES.OK;
};
