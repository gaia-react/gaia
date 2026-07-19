/**
 * Pure tally core for the policy-memory loop.
 *
 * Turns recorded code-review-audit findings (already extracted from the
 * machine-readable PR-comment blocks of the rolling window) into the candidate
 * list the statusline nudge and `/gaia-harden review` consume. No I/O lives
 * here: the caller resolves the PR window, parses the comment blocks, and wires
 * the suppression inputs (promoted rules, the decline ledger) as predicates.
 *
 * A finding_class becomes a candidate once it recurs across at least
 * `RECURRENCE_THRESHOLD` DISTINCT PRs, at any severity, is not already covered
 * by a promoted rule, and is not currently suppressed by the decline ledger.
 * `severity_max` is a running max across the recurrence, not an eligibility
 * gate. A classless finding (the `holistic/unclassified` fallback) recurs the
 * same way but routes to the separate `unclassified` signal instead: it is
 * never a candidate, never covered, and never suppressed. Findings repeated
 * within a single PR still collapse to one distinct-PR increment either way.
 */
import {
  isOracleFindingClass,
  isValidFindingClass,
  OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
} from '../schemas/finding-class.js';

export const RECURRENCE_THRESHOLD = 3;

export type ComputeTallyArgs = {
  /** True when a promoted rule already covers the class (drop it). */
  coveredClass: (findingClass: string) => boolean;
  prs: readonly TallyPrRecord[];
  /** True when the decline ledger suppresses the class at this PR count. */
  suppressedClass: (findingClass: string, currentPrCount: number) => boolean;
  windowDays: number;
};

// Severity ordering for the running max: error > warning > suggestion.
export type Severity = 'error' | 'suggestion' | 'warning';

export type TallyCandidate = {
  area_tags: string[];
  distinct_pr_count: number;
  finding_class: string;
  is_oracle: boolean;
  pr_numbers: number[];
  severity_max: Severity;
};

export type TallyFinding = {
  area_tags: readonly string[];
  finding_class: string;
  severity: Severity;
};

export type TallyPrRecord = {
  findings: readonly TallyFinding[];
  pr_number: number;
};

export type TallyResult = {
  candidate_count: number;
  candidates: TallyCandidate[];
  unclassified: null | UnclassifiedSignal;
  window_days: number;
};

// The single classless recurrence signal (one stable key, cardinality one):
// every `holistic/unclassified` finding in a PR collapses under this one
// bucket regardless of how many there are.
export type UnclassifiedSignal = {
  area_tags: string[];
  distinct_pr_count: number;
  pr_numbers: number[];
  severity_max: Severity;
};

const SEVERITY_RANK: Record<Severity, number> = {
  error: 3,
  suggestion: 1,
  warning: 2,
};

const maxSeverity = (a: Severity, b: Severity): Severity =>
  SEVERITY_RANK[a] >= SEVERITY_RANK[b] ? a : b;

type ClassAggregate = {
  areaTags: string[];
  prNumbers: number[];
  severityMax: Severity;
};

type PerPrCollapse = {
  areaTags: Map<string, Set<string>>;
  severity: Map<string, Severity>;
};

// Collapses one PR's findings into per-key aggregates so a key counts once
// per PR regardless of how many findings carry it, tracking the PR-local
// severity max (running max across error > warning > suggestion) and the
// union of area tags seen for it. A key is either a valid finding_class or
// the `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` constant, standing in for the
// classless "unclassified" bucket. Free-text / unseeded finding_class values
// are skipped.
const collapsePr = (pr: TallyPrRecord): PerPrCollapse => {
  const severity = new Map<string, Severity>();
  const areaTags = new Map<string, Set<string>>();

  // Free-text / unseeded finding_class values are skipped; only the classless
  // bucket key and valid seeded/oracle classes are aggregated.
  const aggregated = pr.findings.filter(
    (finding) =>
      finding.finding_class === OUT_OF_SCOPE_FALLBACK_FINDING_CLASS ||
      isValidFindingClass(finding.finding_class)
  );

  for (const finding of aggregated) {
    const key = finding.finding_class;
    const existing = severity.get(key);

    severity.set(
      key,
      existing === undefined ?
        finding.severity
      : maxSeverity(existing, finding.severity)
    );

    const tags = areaTags.get(key) ?? new Set<string>();

    for (const tag of finding.area_tags) tags.add(tag);
    areaTags.set(key, tags);
  }

  return {areaTags, severity};
};

type MergeAggregateArgs = {
  byClass: Map<string, ClassAggregate>;
  findingClass: string;
  prNumber: number;
  severity: Severity;
  tags: ReadonlySet<string>;
};

// Merges one PR's collapsed severity/tags for a class into its running
// aggregate, creating the aggregate on first sight and otherwise taking the
// running max of the aggregate's severity against this PR's local severity.
const mergeAggregate = ({
  byClass,
  findingClass,
  prNumber,
  severity,
  tags,
}: MergeAggregateArgs): void => {
  const existing = byClass.get(findingClass);
  const aggregate: ClassAggregate = existing ?? {
    areaTags: [],
    prNumbers: [],
    severityMax: severity,
  };

  if (existing !== undefined) {
    aggregate.severityMax = maxSeverity(aggregate.severityMax, severity);
  }

  aggregate.prNumbers.push(prNumber);

  const seenTags = new Set(aggregate.areaTags);

  for (const tag of tags) {
    if (!seenTags.has(tag)) {
      aggregate.areaTags.push(tag);
      seenTags.add(tag);
    }
  }

  byClass.set(findingClass, aggregate);
};

/**
 * Folds the window's PRs into a per-key aggregate, where the key is either a
 * valid finding_class or the `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` constant
 * standing in for the classless "unclassified" bucket. A key is counted at
 * most once per PR (same-key collapse): repeated findings under one key
 * inside a single PR contribute a single distinct-PR increment. Free-text /
 * unseeded finding_class values are skipped.
 */
const aggregateByClass = (
  prs: readonly TallyPrRecord[]
): Map<string, ClassAggregate> => {
  const byClass = new Map<string, ClassAggregate>();

  for (const pr of prs) {
    const {areaTags, severity} = collapsePr(pr);

    for (const [findingClass, findingSeverity] of severity) {
      mergeAggregate({
        byClass,
        findingClass,
        prNumber: pr.pr_number,
        severity: findingSeverity,
        tags: areaTags.get(findingClass) ?? new Set<string>(),
      });
    }
  }

  return byClass;
};

export const computeTally = ({
  coveredClass,
  prs,
  suppressedClass,
  windowDays,
}: ComputeTallyArgs): TallyResult => {
  const byClass = aggregateByClass(prs);

  const candidates: TallyCandidate[] = [];
  let unclassified: null | UnclassifiedSignal = null;

  for (const [findingClass, aggregate] of byClass) {
    const distinctPrCount = aggregate.prNumbers.length;

    // The classless bucket is subject to the threshold only: never covered,
    // never suppressed, never a candidate (see the module docblock).
    if (findingClass === OUT_OF_SCOPE_FALLBACK_FINDING_CLASS) {
      if (distinctPrCount >= RECURRENCE_THRESHOLD) {
        unclassified = {
          area_tags: aggregate.areaTags,
          distinct_pr_count: distinctPrCount,
          pr_numbers: aggregate.prNumbers,
          severity_max: aggregate.severityMax,
        };
      }
    } else {
      const qualifies =
        distinctPrCount >= RECURRENCE_THRESHOLD &&
        !coveredClass(findingClass) &&
        !suppressedClass(findingClass, distinctPrCount);

      if (qualifies) {
        candidates.push({
          area_tags: aggregate.areaTags,
          distinct_pr_count: distinctPrCount,
          finding_class: findingClass,
          is_oracle: isOracleFindingClass(findingClass),
          pr_numbers: aggregate.prNumbers,
          severity_max: aggregate.severityMax,
        });
      }
    }
  }

  return {
    candidate_count: candidates.length,
    candidates,
    unclassified,
    window_days: windowDays,
  };
};

/**
 * The set of valid finding_class values with qualifying recurrence evidence
 * (>= threshold distinct PRs, any severity) in the window, before any
 * suppression/coverage filtering. Excludes the classless `unclassified`
 * bucket, which never enters the decline ledger (see the module docblock).
 * The ledger-prune pass consumes this so it can drop decline entries whose
 * class no longer recurs.
 */
export const windowClasses = (prs: readonly TallyPrRecord[]): string[] => {
  const byClass = aggregateByClass(prs);
  const classes: string[] = [];

  for (const [findingClass, aggregate] of byClass) {
    if (
      findingClass !== OUT_OF_SCOPE_FALLBACK_FINDING_CLASS &&
      aggregate.prNumbers.length >= RECURRENCE_THRESHOLD
    ) {
      classes.push(findingClass);
    }
  }

  return classes;
};
