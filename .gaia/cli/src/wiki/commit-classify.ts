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
 *      `style:` : SKIP regardless.
 *   2. Body contains `BREAKING CHANGE` OR subject is `feat!:` OR
 *      `docs(decision):` OR `chore(adr):` : WORTHY.
 *   3. Touches `wiki/decisions/`, `wiki/concepts/`, `wiki/flows/`,
 *      `wiki/dependencies/`, or `wiki/entities/` : WORTHY.
 *   4. Touches `app/middleware/**`, `app/routes.ts`, `app/i18n.ts`, or
 *      `app/sessions.server/**` : WORTHY (flows-relevant).
 *   5. `chore(deps):`, `chore(cli):`, `wiki:` : SKIP unless body mentions
 *      `architecture` or trade-off / invariant / gotcha keywords.
 *   6. `feat:` / `fix:` / `refactor:` touching `app/**` non-test files:
 *      WORTHY.
 *   7. `feat:` / `fix:` / `refactor:` touching only test files OR
 *      pages/components/hooks/services without body decision keywords:
 *      SKIP (Serena handles inventory).
 *   8. `chore:`, `docs:`, `test:` (without earlier override): SKIP.
 *   9. Anything else: WORTHY (false positive better than false negative).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {commitDetails, resolveRepoRoot} from './util/git.js';
import type {CommitDetail} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki commit-classify --since <sha> [--json]

  Emit a deterministic WORTHY/SKIP suggestion for every commit in
  <sha>..HEAD. Without --json, prints a tabular summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

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

export type CommitSuggestion = 'SKIP' | 'WORTHY';

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseSuccess = {
  flags: {json: boolean; since: string};
  ok: true;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as
  // `string`, not `string | undefined`; check the bound explicitly instead
  // of comparing the indexed value to `undefined`.
  if (index >= argv.length) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

const parseFlags = (
  argv: readonly string[]
): FlagParseFailure | FlagParseSuccess => {
  let since: string | undefined;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--since') {
      const taken = takeValue(argv, index + 1, '--since');

      if (!taken.ok) return taken;
      since = taken.value;
      index += 1;
    } else if (token === '--json') {
      json = true;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
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

const touchesAny = (
  files: readonly string[],
  prefixes: readonly string[]
): boolean =>
  files.some((file) => prefixes.some((prefix) => file.startsWith(prefix)));

const touchesAppNonTest = (files: readonly string[]): boolean =>
  files.some((file) => file.startsWith('app/') && !file.includes('.test.'));

const touchesOnlyTests = (files: readonly string[]): boolean =>
  files.length > 0 && files.every((file) => file.includes('.test.'));

type ClassifyDecision = {reason: string; suggestion: CommitSuggestion};

// Rule 1: hard-skip prefixes, regardless of anything else.
const classifyHardSkip = (
  commit: CommitDetail
): ClassifyDecision | undefined => {
  const {subject} = commit;

  if (subject.startsWith('Merge pull request')) {
    return {reason: 'merge commit', suggestion: 'SKIP'};
  }

  if (subject.startsWith('chore(release):')) {
    return {reason: 'chore(release): release plumbing', suggestion: 'SKIP'};
  }

  if (subject.startsWith('style:')) {
    return {reason: 'style: formatting only', suggestion: 'SKIP'};
  }

  return undefined;
};

// Rule 2: strong WORTHY signals.
const classifyStrongWorthy = (
  commit: CommitDetail
): ClassifyDecision | undefined => {
  const {body, subject} = commit;

  if (subject.startsWith('feat!:') || body.includes('BREAKING CHANGE')) {
    return {reason: 'breaking change signal', suggestion: 'WORTHY'};
  }

  if (
    subject.startsWith('docs(decision):') ||
    subject.startsWith('chore(adr):')
  ) {
    return {reason: 'explicit ADR signal', suggestion: 'WORTHY'};
  }

  return undefined;
};

// Rules 3/4: touches a wiki-heavy domain or a flows-relevant app path.
const classifyTouchedDomains = (
  commit: CommitDetail
): ClassifyDecision | undefined => {
  const {files} = commit;

  if (touchesAny(files, WIKI_HEAVY_DOMAINS)) {
    return {reason: 'touches wiki-heavy domain', suggestion: 'WORTHY'};
  }

  if (touchesAny(files, FLOWS_RELEVANT_PATHS)) {
    return {reason: 'touches flows-relevant path', suggestion: 'WORTHY'};
  }

  return undefined;
};

// Rule 5: architecture-suppressible chore prefixes.
const classifyArchSuppressibleChore = (
  commit: CommitDetail
): ClassifyDecision | undefined => {
  const {body, subject} = commit;

  if (subject.startsWith('chore(deps):')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {
          reason: 'chore(deps): body mentions architecture / decision',
          suggestion: 'WORTHY',
        }
      : {reason: 'chore(deps): version bump only', suggestion: 'SKIP'};
  }

  if (subject.startsWith('chore(cli):')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {
          reason: 'chore(cli): body mentions architecture / decision',
          suggestion: 'WORTHY',
        }
      : {reason: 'chore(cli): tooling-internal', suggestion: 'SKIP'};
  }

  if (subject.startsWith('wiki:')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {reason: 'wiki: body mentions architecture', suggestion: 'WORTHY'}
      : {reason: 'wiki: self-referential', suggestion: 'SKIP'};
  }

  return undefined;
};

// Rules 6/7: feat/fix/refactor touching app/** non-test → WORTHY; tests-only
// or app inventory paths without decision keywords → SKIP.
const classifyFeatureCommit = (
  commit: CommitDetail
): ClassifyDecision | undefined => {
  const {body, files, subject} = commit;
  const isFeatureCommit =
    subject.startsWith('feat:') ||
    subject.startsWith('fix:') ||
    subject.startsWith('refactor:');

  if (!isFeatureCommit) return undefined;

  if (touchesOnlyTests(files)) {
    return {reason: 'feat/fix/refactor: tests-only', suggestion: 'SKIP'};
  }

  const onlyInventory =
    files.length > 0 &&
    files.every((file) =>
      APP_INVENTORY_PREFIXES.some((prefix) => file.startsWith(prefix))
    );

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
};

// Rules 8/9: catch-all chore / docs / test prefixes, else default to WORTHY
// (a false positive is cheaper than a false negative here).
const classifyCatchAll = (commit: CommitDetail): ClassifyDecision => {
  const {body, subject} = commit;

  if (subject.startsWith('chore:')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {reason: 'chore: body mentions architecture', suggestion: 'WORTHY'}
      : {reason: 'chore: generic chore', suggestion: 'SKIP'};
  }

  if (subject.startsWith('docs:')) {
    return {reason: 'docs: prose-only', suggestion: 'SKIP'};
  }

  if (subject.startsWith('test:')) {
    return {reason: 'test: test-only change', suggestion: 'SKIP'};
  }

  return {
    reason: 'no matching prefix, defer to human review',
    suggestion: 'WORTHY',
  };
};

const classify = (commit: CommitDetail): ClassifyDecision =>
  classifyHardSkip(commit) ??
  classifyStrongWorthy(commit) ??
  classifyTouchedDomains(commit) ??
  classifyArchSuppressibleChore(commit) ??
  classifyFeatureCommit(commit) ??
  classifyCatchAll(commit);

const printHuman = (classification: CommitClassification): void => {
  if (classification.commits.length === 0) {
    process.stdout.write('No commits to classify.\n');

    return;
  }

  const lines = [`Classified ${classification.commits.length} commit(s):`, ''];

  for (const commit of classification.commits) {
    lines.push(
      `  ${commit.sha.slice(0, 7)}  ${commit.suggestion.padEnd(7)}  ${commit.subject}`,
      `            reason: ${commit.suggestion_reason}`,
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
  if (argv.length === 0 || HELP_TOKENS.has(argv[0])) {
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
