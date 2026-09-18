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
 * never a candidate and never covered, but it is subject to the decline
 * ledger's suppression, so a maintainer who seeds the vocabulary a cluster
 * was missing can discharge the signal rather than see it re-surface every
 * tally. Findings repeated within a single PR still collapse to one
 * distinct-PR increment either way.
 *
 * `class_inventory` carries every non-fallback class the window counted at
 * least once, below-threshold classes included, so a review snapshot holds
 * the full picture and a class crossing the threshold later reads as a rise
 * rather than a "new pattern". `audited_pr_count` is the window's denominator
 * (`prs.length`), passed to `suppressedClass` alongside each class's own
 * count so the decline ledger can compare shares instead of raw counts.
 */
import {
  isOracleFindingClass,
  isValidFindingClass,
  OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
} from '../schemas/finding-class.js';

export const RECURRENCE_THRESHOLD = 3;

export type ClassInventoryEntry = {
  distinct_pr_count: number;
  finding_class: string;
};

export type ComputeTallyArgs = {
  /** True when a promoted rule already covers the class (drop it). */
  coveredClass: (findingClass: string) => boolean;
  prs: readonly TallyPrRecord[];
  /**
   * True when the decline ledger suppresses the class at this PR count out of
   * this audited-PR denominator (the window's total audited-PR count, passed
   * unconditionally so the ledger's share-based rule can compare against it).
   */
  suppressedClass: (
    findingClass: string,
    currentPrCount: number,
    currentAuditedPrCount: number
  ) => boolean;
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
  audited_pr_count: number;
  candidate_count: number;
  candidates: TallyCandidate[];
  class_inventory: ClassInventoryEntry[];
  unclassified: null | UnclassifiedSignal;
  unclassified_window_count: null | number;
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

// tally-semantics:start
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
// tally-semantics:end

type FallbackOutcome = {
  unclassified: null | UnclassifiedSignal;
  unclassifiedWindowCount: null | number;
};

type FallbackOutcomeArgs = {
  aggregate: ClassAggregate;
  atThreshold: boolean;
  distinctPrCount: number;
  suppressed: boolean;
};

// The classless bucket is never covered and never a candidate, but its
// surfacing is gated by the decline ledger's suppression like every seeded
// class, and it never joins the inventory of seeded classes.
const fallbackOutcome = ({
  aggregate,
  atThreshold,
  distinctPrCount,
  suppressed,
}: FallbackOutcomeArgs): FallbackOutcome => ({
  unclassified:
    atThreshold && !suppressed ?
      {
        area_tags: aggregate.areaTags,
        distinct_pr_count: distinctPrCount,
        pr_numbers: aggregate.prNumbers,
        severity_max: aggregate.severityMax,
      }
    : null,
  unclassifiedWindowCount:
    distinctPrCount >= 1 && !suppressed ? distinctPrCount : null,
});

type SeededEntry = {
  candidate: null | TallyCandidate;
  inventoryEntry: ClassInventoryEntry | null;
};

type SeededEntryArgs = {
  aggregate: ClassAggregate;
  atThreshold: boolean;
  covered: boolean;
  distinctPrCount: number;
  findingClass: string;
  suppressed: boolean;
};

const seededEntry = ({
  aggregate,
  atThreshold,
  covered,
  distinctPrCount,
  findingClass,
  suppressed,
}: SeededEntryArgs): SeededEntry => {
  const eligible = !covered && !suppressed;

  return {
    candidate:
      atThreshold && eligible ?
        {
          area_tags: aggregate.areaTags,
          distinct_pr_count: distinctPrCount,
          finding_class: findingClass,
          is_oracle: isOracleFindingClass(findingClass),
          pr_numbers: aggregate.prNumbers,
          severity_max: aggregate.severityMax,
        }
      : null,
    inventoryEntry:
      distinctPrCount >= 1 && eligible ?
        {distinct_pr_count: distinctPrCount, finding_class: findingClass}
      : null,
  };
};

type ClassOutcome = FallbackOutcome & SeededEntry;

type ClassOutcomeArgs = {
  aggregate: ClassAggregate;
  auditedPrCount: number;
  coveredClass: ComputeTallyArgs['coveredClass'];
  findingClass: string;
  suppressedClass: ComputeTallyArgs['suppressedClass'];
};

// One class's full disposition (candidate, inventory entry, and/or the
// fallback signal), so the loop in `computeTally` stays a flat sequence of
// null-checks rather than branching on the fallback class itself.
const classOutcome = ({
  aggregate,
  auditedPrCount,
  coveredClass,
  findingClass,
  suppressedClass,
}: ClassOutcomeArgs): ClassOutcome => {
  const distinctPrCount = aggregate.prNumbers.length;
  const atThreshold = distinctPrCount >= RECURRENCE_THRESHOLD;
  // Below-threshold keys are never queried: this run's ledger prune drops any
  // decline whose class fell below the threshold, so a below-threshold key
  // has no live decline to honor, and skipping the query avoids one process
  // spawn per rare class.
  const suppressed =
    atThreshold ?
      suppressedClass(findingClass, distinctPrCount, auditedPrCount)
    : false;

  if (findingClass === OUT_OF_SCOPE_FALLBACK_FINDING_CLASS) {
    return {
      candidate: null,
      inventoryEntry: null,
      ...fallbackOutcome({aggregate, atThreshold, distinctPrCount, suppressed}),
    };
  }

  return {
    ...seededEntry({
      aggregate,
      atThreshold,
      covered: coveredClass(findingClass),
      distinctPrCount,
      findingClass,
      suppressed,
    }),
    unclassified: null,
    unclassifiedWindowCount: null,
  };
};

export const computeTally = ({
  coveredClass,
  prs,
  suppressedClass,
  windowDays,
}: ComputeTallyArgs): TallyResult => {
  const byClass = aggregateByClass(prs);
  const auditedPrCount = prs.length;

  const candidates: TallyCandidate[] = [];
  const classInventory: ClassInventoryEntry[] = [];
  let unclassified: null | UnclassifiedSignal = null;
  let unclassifiedWindowCount: null | number = null;

  for (const [findingClass, aggregate] of byClass) {
    const outcome = classOutcome({
      aggregate,
      auditedPrCount,
      coveredClass,
      findingClass,
      suppressedClass,
    });

    if (outcome.candidate !== null) candidates.push(outcome.candidate);

    if (outcome.inventoryEntry !== null) {
      classInventory.push(outcome.inventoryEntry);
    }
    if (outcome.unclassified !== null) unclassified = outcome.unclassified;

    if (outcome.unclassifiedWindowCount !== null) {
      unclassifiedWindowCount = outcome.unclassifiedWindowCount;
    }
  }

  return {
    audited_pr_count: auditedPrCount,
    candidate_count: candidates.length,
    candidates,
    class_inventory: classInventory,
    unclassified,
    unclassified_window_count: unclassifiedWindowCount,
    window_days: windowDays,
  };
};

/**
 * The set of keys with qualifying recurrence evidence (>= threshold distinct
 * PRs, any severity) in the window, before any suppression/coverage filtering.
 * The ledger-prune pass consumes this so it can drop decline entries whose key
 * no longer recurs.
 *
 * The classless `unclassified` bucket is included on the same terms as every
 * seeded class. It is declinable, so its stored baseline has to be released
 * once the cluster that justified it leaves the window; excluding it here
 * would leave a high-water baseline governing whatever unrelated cluster
 * arrives next. A failed window read never reaches the prune (see the `ghOk`
 * gate in `tally.ts`), so an empty list here means evidence of absence rather
 * than absence of evidence.
 */
export const windowClasses = (prs: readonly TallyPrRecord[]): string[] => {
  const byClass = aggregateByClass(prs);
  const classes: string[] = [];

  for (const [findingClass, aggregate] of byClass) {
    if (aggregate.prNumbers.length >= RECURRENCE_THRESHOLD) {
      classes.push(findingClass);
    }
  }

  return classes;
};
