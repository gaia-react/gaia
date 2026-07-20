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
 *   1. `Merge pull request`, `chore(release):`, `style:` : SKIP regardless.
 *   2. Body contains `BREAKING CHANGE` OR subject is `feat!:` (scoped or
 *      not) OR `docs(decision):` OR `chore(adr):` : WORTHY.
 *   3. Touches `wiki/decisions/`, `wiki/concepts/`, `wiki/flows/`,
 *      `wiki/dependencies/`, or `wiki/entities/` : WORTHY.
 *   4. Touches `app/middleware/**`, `app/routes.ts`, `app/i18n.ts`, or
 *      `app/sessions.server/**` : WORTHY (flows-relevant).
 *   5. `chore(deps):`, `chore(cli):`, `wiki:`, `ci:`, `build:` : SKIP unless
 *      body mentions `architecture` or trade-off / invariant / gotcha
 *      keywords.
 *   6. `feat:` / `fix:` / `refactor:` / `debt:` touching `app/**` non-test
 *      files: WORTHY.
 *   7. Those same types touching only test files OR
 *      pages/components/hooks/services without body decision keywords:
 *      SKIP (Serena handles inventory).
 *   8. `chore:`, `docs:`, `test:` (without earlier override): SKIP.
 *   9. Anything else: WORTHY (false positive better than false negative).
 *
 * Every type match reads a parsed conventional-commit prefix, so a scoped or
 * breaking-marked subject reaches the same rule as its bare equivalent:
 * `fix:`, `fix(hooks):`, `fix!:`, and `fix(hooks)!:` are all rule 6. Rules
 * keyed on a specific scope (`chore(deps):`, `docs(decision):`) live in
 * earlier groups than their generic counterparts, so they still win.
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

type SubjectPrefix = {
  breaking: boolean;
  scope: string | undefined;
  type: string;
};

/**
 * Conventional-commit subject prefix: a type, an optional `(scope)`, and an
 * optional `!` breaking marker. Testing `subject.startsWith('fix:')` matches
 * only the bare form, so on a repo that writes scoped subjects every rule
 * keyed that way is unreachable and the whole table silently falls through to
 * the rule 9 default. Parse the prefix once and match on its parts instead.
 */
// `breaking` is `(?<bang>!?)` rather than an optional group so it always
// participates and captures `''` or `'!'`, matching the release modules'
// reading of the same grammar. `noUncheckedIndexedAccess` is off, so an
// optional group's `undefined` is invisible to the type checker and a
// `!== undefined` test would be statically meaningless.
const SUBJECT_PREFIX_PATTERN =
  /^(?<type>[a-z]+)(?:\((?<scope>[^)]*)\))?(?<breaking>!?):/u;

const parseSubjectPrefix = (subject: string): SubjectPrefix | undefined => {
  const groups = SUBJECT_PREFIX_PATTERN.exec(subject)?.groups;

  if (!groups) return undefined;

  return {
    breaking: groups.breaking === '!',
    scope: groups.scope,
    type: groups.type,
  };
};

// Matches a prefix by type, and by scope when one is named. Every rule below
// goes through this rather than reaching into `prefix` directly, so a new
// rule cannot reintroduce a bare-prefix test that silently never fires.
const matchesPrefix = (
  prefix: SubjectPrefix | undefined,
  type: string,
  scope?: string
): boolean =>
  prefix?.type === type && (scope === undefined || prefix.scope === scope);

// Rules 6/7 treat these as source-bearing work. `debt:` belongs here: a
// tech-debt fix is an ordinary source change and gets the same path-based
// discrimination as `fix:`, not a blanket skip.
const FEATURE_TYPES = ['debt', 'feat', 'fix', 'refactor'];

// Rule 1: hard-skip prefixes, regardless of anything else.
const classifyHardSkip = (
  commit: CommitDetail,
  prefix: SubjectPrefix | undefined
): ClassifyDecision | undefined => {
  if (commit.subject.startsWith('Merge pull request')) {
    return {reason: 'merge commit', suggestion: 'SKIP'};
  }

  if (matchesPrefix(prefix, 'chore', 'release')) {
    return {reason: 'chore(release): release plumbing', suggestion: 'SKIP'};
  }

  if (matchesPrefix(prefix, 'style')) {
    return {reason: 'style: formatting only', suggestion: 'SKIP'};
  }

  return undefined;
};

// Rule 2: strong WORTHY signals.
const classifyStrongWorthy = (
  commit: CommitDetail,
  prefix: SubjectPrefix | undefined
): ClassifyDecision | undefined => {
  const {body} = commit;

  if (
    (matchesPrefix(prefix, 'feat') && prefix?.breaking) ||
    body.includes('BREAKING CHANGE')
  ) {
    return {reason: 'breaking change signal', suggestion: 'WORTHY'};
  }

  if (
    matchesPrefix(prefix, 'docs', 'decision') ||
    matchesPrefix(prefix, 'chore', 'adr')
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

// Rule 5: architecture-suppressible tooling prefixes. `ci:` and `build:` are
// plumbing of the same character as `chore(cli):`, so they skip the routine
// runs and keep the ones whose body records a decision.
const classifyArchSuppressibleChore = (
  commit: CommitDetail,
  prefix: SubjectPrefix | undefined
): ClassifyDecision | undefined => {
  const {body} = commit;
  const suppressible = (label: string, skipReason: string): ClassifyDecision =>
    ARCH_BODY_PATTERN.test(body) ?
      {
        reason: `${label}: body mentions architecture / decision`,
        suggestion: 'WORTHY',
      }
    : {reason: skipReason, suggestion: 'SKIP'};

  if (matchesPrefix(prefix, 'chore', 'deps')) {
    return suppressible('chore(deps)', 'chore(deps): version bump only');
  }

  if (matchesPrefix(prefix, 'chore', 'cli')) {
    return suppressible('chore(cli)', 'chore(cli): tooling-internal');
  }

  if (matchesPrefix(prefix, 'wiki')) {
    return suppressible('wiki', 'wiki: self-referential');
  }

  if (matchesPrefix(prefix, 'ci')) {
    return suppressible('ci', 'ci: CI plumbing');
  }

  if (matchesPrefix(prefix, 'build')) {
    return suppressible('build', 'build: bundling / build plumbing');
  }

  return undefined;
};

// Rules 6/7: feat/fix/refactor/debt touching app/** non-test → WORTHY;
// tests-only or app inventory paths without decision keywords → SKIP.
const classifyFeatureCommit = (
  commit: CommitDetail,
  prefix: SubjectPrefix | undefined
): ClassifyDecision | undefined => {
  const {body, files} = commit;

  if (!prefix || !FEATURE_TYPES.includes(prefix.type)) return undefined;

  if (touchesOnlyTests(files)) {
    return {reason: 'feat/fix/refactor/debt: tests-only', suggestion: 'SKIP'};
  }

  const onlyInventory =
    files.length > 0 &&
    files.every((file) =>
      APP_INVENTORY_PREFIXES.some((inventoryPrefix) =>
        file.startsWith(inventoryPrefix)
      )
    );

  if (onlyInventory && !ARCH_BODY_PATTERN.test(body)) {
    return {
      reason:
        'feat/fix/refactor/debt: only inventory paths (Serena handles inventory)',
      suggestion: 'SKIP',
    };
  }

  if (touchesAppNonTest(files)) {
    return {
      reason: 'feat/fix/refactor/debt: app/** non-test',
      suggestion: 'WORTHY',
    };
  }

  return {
    reason: 'feat/fix/refactor/debt: defer to human review',
    suggestion: 'WORTHY',
  };
};

// Rules 8/9: catch-all chore / docs / test prefixes, else default to WORTHY
// (a false positive is cheaper than a false negative here).
const classifyCatchAll = (
  commit: CommitDetail,
  prefix: SubjectPrefix | undefined
): ClassifyDecision => {
  const {body} = commit;

  if (matchesPrefix(prefix, 'chore')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {reason: 'chore: body mentions architecture', suggestion: 'WORTHY'}
      : {reason: 'chore: generic chore', suggestion: 'SKIP'};
  }

  if (matchesPrefix(prefix, 'docs')) {
    return {reason: 'docs: prose-only', suggestion: 'SKIP'};
  }

  if (matchesPrefix(prefix, 'test')) {
    return {reason: 'test: test-only change', suggestion: 'SKIP'};
  }

  return {
    reason: 'no matching prefix, defer to human review',
    suggestion: 'WORTHY',
  };
};

const classify = (commit: CommitDetail): ClassifyDecision => {
  const prefix = parseSubjectPrefix(commit.subject);

  return (
    classifyHardSkip(commit, prefix) ??
    classifyStrongWorthy(commit, prefix) ??
    classifyTouchedDomains(commit) ??
    classifyArchSuppressibleChore(commit, prefix) ??
    classifyFeatureCommit(commit, prefix) ??
    classifyCatchAll(commit, prefix)
  );
};

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
