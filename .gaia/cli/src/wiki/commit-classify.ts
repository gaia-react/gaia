/**
 * `gaia wiki commit-classify --since <sha> [--json]` handler.
 *
 * Walks every commit in `<since>..HEAD` and emits a deterministic
 * WORTHY/SKIP suggestion plus the rule that fired. Replaces the
 * subject-only first pass in `wiki/sync.md` Step 3.
 *
 * This module is the WORTHY/SKIP contract. The sync playbook at
 * `.claude/skills/gaia/references/wiki/sync.md` defers to it ("Trust the CLI's
 * classification, do not re-derive WORTHY/SKIP rules in prose"), so the rule
 * precedence below is the source of truth and the playbook mirrors it, not the
 * other way round.
 *
 * Rule precedence (first match wins):
 *
 *   1. `Merge pull request`, `chore(release):`, `style:` : SKIP regardless,
 *      ahead of rule 2's breaking marker. Both categories are mechanical, so
 *      a `!` on them is meaningless or still plumbing.
 *   2. Body contains `BREAKING CHANGE` OR subject carries a `!` breaking
 *      marker on any type OR is `docs(decision[s]):` OR `chore(adr):`:
 *      WORTHY.
 *   3. Touches `wiki/decisions/`, `wiki/concepts/`, `wiki/flows/`,
 *      `wiki/dependencies/`, or `wiki/entities/` : WORTHY.
 *   4. Touches `app/middleware/**`, `app/routes.ts`, `app/i18n.ts`, or
 *      `app/sessions.server/**` : WORTHY (flows-relevant).
 *   5. `chore(deps):`, `chore(cli):`, `wiki:`, `ci:`, `build:` : SKIP unless
 *      body mentions `architecture` or trade-off / invariant / gotcha
 *      keywords.
 *   6. `feat:` / `fix:` / `perf:` / `refactor:` / `debt:` touching a
 *      configured source-bearing non-test path: WORTHY.
 *   7. Those same types touching only test files OR only configured inventory
 *      paths without body decision keywords: SKIP (Serena handles inventory).
 *   8. `chore:`, `docs:`, `test:` (without earlier override): SKIP.
 *   9. Anything else: WORTHY (false positive better than false negative).
 *
 * Every type match reads a parsed conventional-commit header from
 * `util/conventional-commit.ts`, so a scoped or breaking-marked subject
 * reaches the same rule as its bare equivalent: `fix:`, `fix(hooks):`,
 * `fix!:`, and `fix(hooks)!:` are all rule 6. Rules keyed on a specific scope
 * (`chore(deps):`, `docs(decision):`) live in earlier groups than their
 * generic counterparts, so they still win.
 *
 * Rules 6/7's path vocabulary is configurable per repo
 * (`util/../wiki/classify-paths.ts`); hardcoded `app/**` literals were
 * unreachable in any repo whose source lives elsewhere.
 *
 * The emitted `health` block reports what share of commits reached a fail-open
 * default rather than a discriminating rule. That is the signal for the rule
 * table having gone inert: individual fail-open commits are fine and expected,
 * but a run where most commits land there looks healthy per-commit while the
 * deterministic first pass has silently stopped filtering.
 *
 * Known edge of that metric: it only sees a rule dying INTO a fail-open
 * default. A rule that dies into another discriminating rule is invisible to
 * it, e.g. renaming the `chore(deps):` convention would strand rule 5 while
 * those commits landed on rule 8's `chore` arm, keeping the deferral rate at
 * zero. Catching that needs a per-rule histogram against a persisted
 * cross-sync baseline, which is more machinery than the observed failures
 * justify.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  isCommitType,
  parseConventionalCommitHeader,
} from '../util/conventional-commit.js';
import type {
  CommitType,
  ConventionalCommitHeader,
} from '../util/conventional-commit.js';
import {readClassifyPaths} from './classify-paths.js';
import type {ClassifyPaths} from './classify-paths.js';
import {commitDetails, resolveRepoRoot} from './util/git.js';
import type {CommitDetail} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki commit-classify --since <sha> [--json]

  Emit a deterministic WORTHY/SKIP suggestion for every commit in
  <sha>..HEAD. Without --json, prints a tabular summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type ClassificationHealth = {
  /** `deferred / evaluated`, or 0 when nothing was evaluated. */
  deferral_rate: number;
  /** Commits whose decision came from a fail-open default. */
  deferred: number;
  /** Commits classified. */
  evaluated: number;
  /** True when the sample is large enough AND the deferral rate exceeds the threshold. */
  inert: boolean;
  threshold: number;
  /** Reported alongside the deferral rate so a high WORTHY share stays visible even when the rules are discriminating. */
  worthy_rate: number;
};

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
  health: ClassificationHealth;
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

const touchesAny = (
  files: readonly string[],
  prefixes: readonly string[]
): boolean =>
  files.some((file) => prefixes.some((prefix) => file.startsWith(prefix)));

const isTestFile = (file: string, paths: ClassifyPaths): boolean =>
  file.includes('.test.') ||
  paths.testPaths.some((prefix) => file.startsWith(prefix));

const touchesSourceNonTest = (
  files: readonly string[],
  paths: ClassifyPaths
): boolean =>
  files.some(
    (file) =>
      paths.sourcePaths.some((prefix) => file.startsWith(prefix)) &&
      !isTestFile(file, paths)
  );

const touchesOnlyTests = (
  files: readonly string[],
  paths: ClassifyPaths
): boolean =>
  files.length > 0 && files.every((file) => isTestFile(file, paths));

type ClassifyDecision = {
  /**
   * Set only on the fail-open defaults: the rule table could not discriminate
   * this commit. Feeds the health signal; every rule that actually matched
   * leaves it unset.
   */
  deferred?: boolean;
  reason: string;
  suggestion: CommitSuggestion;
};

// Matches a header by type, and by scope when one is named. Every rule below
// goes through this rather than reaching into `header` directly, so a new
// rule cannot reintroduce a bare-prefix test that silently never fires:
// testing `subject.startsWith('fix:')` matches only the unscoped form, and on
// a repo that writes scoped subjects that rule is unreachable.
const matchesPrefix = (
  header: ConventionalCommitHeader | undefined,
  type: string,
  scope?: string
): boolean =>
  header?.type === type && (scope === undefined || header.scope === scope);

/**
 * Which types rules 6/7 discriminate by path. `debt` and `perf` are `true`:
 * both are ordinary source changes and earn the same path-based treatment as
 * `fix`, not a blanket skip.
 *
 * A `Record<CommitType, boolean>` rather than a `string[]` for the same reason
 * the release and changelog tables are keyed that way: adding a type to the
 * vocabulary must not be able to slip past this table and land on the rule-9
 * fail-open, which is precisely how `debt` went years without a rule.
 */
const PATH_DISCRIMINATED_TYPES: Record<CommitType, boolean> = {
  build: false,
  chore: false,
  ci: false,
  debt: true,
  docs: false,
  feat: true,
  fix: true,
  perf: true,
  refactor: true,
  revert: true,
  style: false,
  test: false,
  wiki: false,
};

// Rule 1: hard-skip prefixes, regardless of anything else.
const classifyHardSkip = (
  commit: CommitDetail,
  header: ConventionalCommitHeader | undefined
): ClassifyDecision | undefined => {
  if (commit.subject.startsWith('Merge pull request')) {
    return {reason: 'merge commit', suggestion: 'SKIP'};
  }

  if (matchesPrefix(header, 'chore', 'release')) {
    return {reason: 'chore(release): release plumbing', suggestion: 'SKIP'};
  }

  if (matchesPrefix(header, 'style')) {
    return {reason: 'style: formatting only', suggestion: 'SKIP'};
  }

  return undefined;
};

// Rule 2: strong WORTHY signals.
const classifyStrongWorthy = (
  commit: CommitDetail,
  header: ConventionalCommitHeader | undefined
): ClassifyDecision | undefined => {
  const {body} = commit;

  // `!` is a breaking marker on ANY type, matching Conventional Commits and
  // the release bump's reading of the same grammar. Scoping this to `feat`
  // would let `chore(cli)!:` reach rule 5 and SKIP a breaking change: the
  // bare-prefix rules used to fail open on the `!`, and once every rule
  // matches breaking-agnostically that accident is no longer there to help.
  if (header?.breaking || body.includes('BREAKING CHANGE')) {
    return {reason: 'breaking change signal', suggestion: 'WORTHY'};
  }

  // Both spellings: this repo writes `docs(decisions):`, and the singular is
  // the older convention. Matching only one lets the generic `docs:` rule in
  // rule 8 swallow a real ADR as prose-only.
  if (
    matchesPrefix(header, 'docs', 'decision') ||
    matchesPrefix(header, 'docs', 'decisions') ||
    matchesPrefix(header, 'chore', 'adr')
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
  header: ConventionalCommitHeader | undefined
): ClassifyDecision | undefined => {
  const {body} = commit;
  const suppressible = (label: string, skipReason: string): ClassifyDecision =>
    ARCH_BODY_PATTERN.test(body) ?
      {
        reason: `${label}: body mentions architecture / decision`,
        suggestion: 'WORTHY',
      }
    : {reason: skipReason, suggestion: 'SKIP'};

  if (matchesPrefix(header, 'chore', 'deps')) {
    return suppressible('chore(deps)', 'chore(deps): version bump only');
  }

  if (matchesPrefix(header, 'chore', 'cli')) {
    return suppressible('chore(cli)', 'chore(cli): tooling-internal');
  }

  if (matchesPrefix(header, 'wiki')) {
    return suppressible('wiki', 'wiki: self-referential');
  }

  if (matchesPrefix(header, 'ci')) {
    return suppressible('ci', 'ci: CI plumbing');
  }

  if (matchesPrefix(header, 'build')) {
    return suppressible('build', 'build: bundling / build plumbing');
  }

  return undefined;
};

// Rules 6/7: feat/fix/perf/refactor/debt touching a source-bearing non-test path →
// WORTHY; tests-only or inventory-only without decision keywords → SKIP.
// Every predicate reads the repo's configured path vocabulary rather than
// `app/**` literals, which no repo outside the React template ever matches.
const classifyFeatureCommit = (
  commit: CommitDetail,
  header: ConventionalCommitHeader | undefined,
  paths: ClassifyPaths
): ClassifyDecision | undefined => {
  const {body, files} = commit;

  if (
    header === undefined ||
    !isCommitType(header.type) ||
    !PATH_DISCRIMINATED_TYPES[header.type]
  ) {
    return undefined;
  }

  if (touchesOnlyTests(files, paths)) {
    return {
      reason: 'feat/fix/perf/refactor/debt: tests-only',
      suggestion: 'SKIP',
    };
  }

  const onlyInventory =
    files.length > 0 &&
    files.every((file) =>
      paths.inventoryPaths.some((inventoryPrefix) =>
        file.startsWith(inventoryPrefix)
      )
    );

  if (onlyInventory && !ARCH_BODY_PATTERN.test(body)) {
    return {
      reason:
        'feat/fix/perf/refactor/debt: only inventory paths (Serena handles inventory)',
      suggestion: 'SKIP',
    };
  }

  if (touchesSourceNonTest(files, paths)) {
    return {
      reason: 'feat/fix/perf/refactor/debt: source-bearing path (non-test)',
      suggestion: 'WORTHY',
    };
  }

  // Rule 7's fail-open tail. Unlike rule 9 this carries a specific-sounding
  // reason, which is exactly why it has to count toward the health signal:
  // when the path vocabulary does not match the repo, every source commit
  // lands here and each one looks individually plausible.
  return {
    deferred: true,
    reason: 'feat/fix/perf/refactor/debt: defer to human review',
    suggestion: 'WORTHY',
  };
};

// Rules 8/9: catch-all chore / docs / test prefixes, else default to WORTHY
// (a false positive is cheaper than a false negative here).
const classifyCatchAll = (
  commit: CommitDetail,
  header: ConventionalCommitHeader | undefined
): ClassifyDecision => {
  const {body} = commit;

  if (matchesPrefix(header, 'chore')) {
    return ARCH_BODY_PATTERN.test(body) ?
        {reason: 'chore: body mentions architecture', suggestion: 'WORTHY'}
      : {reason: 'chore: generic chore', suggestion: 'SKIP'};
  }

  // Deliberately unconditional, unlike the `chore` arm above and rule 5: a
  // docs commit that genuinely records a decision is `docs(decision[s]):` and
  // rule 2 already claimed it. Extending the architecture-body escape here
  // would mostly re-promote changelog and prose cleanups that happen to quote
  // a keyword, which is the expensive false positive this pass exists to
  // avoid rather than a decision worth deep-reading.
  if (matchesPrefix(header, 'docs')) {
    return {reason: 'docs: prose-only', suggestion: 'SKIP'};
  }

  if (matchesPrefix(header, 'test')) {
    return {reason: 'test: test-only change', suggestion: 'SKIP'};
  }

  // Rule 9, the fail-open default. Failing open on one unrecognized commit is
  // right; every commit landing here means the table has stopped matching, and
  // that is what the health signal counts.
  return {
    deferred: true,
    reason: 'no matching prefix, defer to human review',
    suggestion: 'WORTHY',
  };
};

const classify = (
  commit: CommitDetail,
  paths: ClassifyPaths
): ClassifyDecision => {
  const header = parseConventionalCommitHeader(commit.subject);

  return (
    classifyHardSkip(commit, header) ??
    classifyStrongWorthy(commit, header) ??
    classifyTouchedDomains(commit) ??
    classifyArchSuppressibleChore(commit, header) ??
    classifyFeatureCommit(commit, header, paths) ??
    classifyCatchAll(commit, header)
  );
};

// Below this many commits a single unusual batch dominates the rate, so the
// detector stays silent rather than crying wolf over a legitimately odd window.
const HEALTH_MIN_SAMPLE = 20;

// Above this share of fail-open defaults the table has stopped discriminating.
//
// Calibrated against both observed inert cases and the healthy state, not
// picked round: the type rules matching only unscoped subjects put 68% of
// commits on rule 9, and the path vocabulary matching nothing in this repo put
// 55% on rule 7's tail. A threshold of 0.6 would have caught the first and
// missed the second. Against a measured healthy rate of 12% on the same
// history, 0.4 separates cleanly from normal while catching both.
const HEALTH_DEFERRAL_THRESHOLD = 0.4;

const computeHealth = (
  decisions: readonly ClassifyDecision[]
): ClassificationHealth => {
  const evaluated = decisions.length;
  const deferred = decisions.filter((decision) => decision.deferred).length;
  const worthy = decisions.filter(
    (decision) => decision.suggestion === 'WORTHY'
  ).length;
  const deferralRate = evaluated === 0 ? 0 : deferred / evaluated;

  return {
    deferral_rate: deferralRate,
    deferred,
    evaluated,
    inert:
      evaluated >= HEALTH_MIN_SAMPLE &&
      deferralRate > HEALTH_DEFERRAL_THRESHOLD,
    threshold: HEALTH_DEFERRAL_THRESHOLD,
    worthy_rate: evaluated === 0 ? 0 : worthy / evaluated,
  };
};

const asPercent = (rate: number): string => `${Math.round(rate * 100)}%`;

// Written to stderr in both output modes: `--json` callers keep a clean stdout
// payload, and the warning still reaches whoever is running the sync.
const warnIfInert = (health: ClassificationHealth): void => {
  if (!health.inert) return;

  process.stderr.write(
    `commit-classify: ${health.deferred} of ${health.evaluated} commits (${asPercent(health.deferral_rate)}) reached a fail-open default, ` +
      `above the ${asPercent(health.threshold)} threshold. The rule table has likely stopped matching the subjects this repo writes; ` +
      'the first pass is not filtering and Step 4 will deep-read nearly the whole range.\n'
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

  const {health} = classification;
  lines.push(
    '',
    `WORTHY ${asPercent(health.worthy_rate)}, fail-open defaults ${health.deferred}/${health.evaluated} (${asPercent(health.deferral_rate)})`
  );
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

  const paths = readClassifyPaths(repoRoot);
  // Paired rather than two index-correlated arrays. `deferred` is an internal
  // health input, so it stays off the published `ClassifiedCommit` shape.
  const classified = details.map((detail) => ({
    decision: classify(detail, paths),
    detail,
  }));

  const classification: CommitClassification = {
    commits: classified.map(({decision, detail}) => ({
      body: detail.body,
      deletions: detail.deletions,
      files_changed: detail.files_changed,
      insertions: detail.insertions,
      sha: detail.sha,
      subject: detail.subject,
      suggestion: decision.suggestion,
      suggestion_reason: decision.reason,
    })),
    health: computeHealth(classified.map(({decision}) => decision)),
  };

  warnIfInert(classification.health);

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(classification)}\n`);
  } else {
    printHuman(classification);
  }

  return EXIT_CODES.OK;
};
