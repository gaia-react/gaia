/**
 * Pure tally core for the policy-memory loop.
 *
 * Turns recorded code-review-audit findings (already extracted from the
 * machine-readable PR-comment blocks of the rolling window) into the candidate
 * list the statusline nudge and `/gaia-harden review` consume. No I/O lives
 * here: the caller resolves the PR window, parses the comment blocks, and wires
 * the suppression inputs (promoted rules, the decline ledger) as predicates.
 *
 * A class becomes a candidate only when it recurs across at least
 * `RECURRENCE_THRESHOLD` DISTINCT PRs at error or warning severity, is not
 * already covered by a promoted rule, and is not currently suppressed by the
 * decline ledger. Suggestion-severity findings and findings repeated within a
 * single PR never qualify.
 */
import {isValidFindingClass} from '../schemas/finding-class.js';

export const RECURRENCE_THRESHOLD = 3;

export type ComputeTallyArgs = {
  /** True when a promoted rule already covers the class (drop it). */
  coveredClass: (findingClass: string) => boolean;
  prs: readonly TallyPrRecord[];
  /** True when the decline ledger suppresses the class at this PR count. */
  suppressedClass: (findingClass: string, currentPrCount: number) => boolean;
  windowDays: number;
};

export type CountableSeverity = 'error' | 'warning';

export type TallyCandidate = {
  area_tags: string[];
  distinct_pr_count: number;
  finding_class: string;
  pr_numbers: number[];
  severity_max: CountableSeverity;
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
  window_days: number;
};

type Severity = 'error' | 'suggestion' | 'warning';

const isCountableSeverity = (
  severity: Severity
): severity is CountableSeverity =>
  severity === 'error' || severity === 'warning';

type ClassAggregate = {
  areaTags: string[];
  prNumbers: number[];
  severityMax: CountableSeverity;
};

/**
 * Folds the window's PRs into a per-class aggregate. A class is counted at most
 * once per PR (same-class collapse): repeated findings of one class inside a
 * single PR contribute a single distinct-PR increment. Class-less / invalid and
 * suggestion-severity findings are dropped before counting.
 */
const aggregateByClass = (
  prs: readonly TallyPrRecord[]
): Map<string, ClassAggregate> => {
  const byClass = new Map<string, ClassAggregate>();

  for (const pr of prs) {
    // Collapse within the PR first so a class counts once per PR regardless of
    // how many findings carry it; track the strongest severity seen for it.
    const perPrSeverity = new Map<string, CountableSeverity>();
    const perPrAreaTags = new Map<string, Set<string>>();

    for (const finding of pr.findings) {
      if (!isCountableSeverity(finding.severity)) continue;
      if (!isValidFindingClass(finding.finding_class)) continue;

      const existing = perPrSeverity.get(finding.finding_class);

      if (existing !== 'error') {
        perPrSeverity.set(finding.finding_class, finding.severity);
      }

      const tags =
        perPrAreaTags.get(finding.finding_class) ?? new Set<string>();

      for (const tag of finding.area_tags) tags.add(tag);
      perPrAreaTags.set(finding.finding_class, tags);
    }

    for (const [findingClass, severity] of perPrSeverity) {
      const aggregate = byClass.get(findingClass) ?? {
        areaTags: [],
        prNumbers: [],
        severityMax: 'warning' as CountableSeverity,
      };

      aggregate.prNumbers.push(pr.pr_number);

      if (severity === 'error') aggregate.severityMax = 'error';

      const seenTags = new Set(aggregate.areaTags);

      for (const tag of perPrAreaTags.get(findingClass) ?? []) {
        if (!seenTags.has(tag)) {
          aggregate.areaTags.push(tag);
          seenTags.add(tag);
        }
      }

      byClass.set(findingClass, aggregate);
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

  for (const [findingClass, aggregate] of byClass) {
    const distinctPrCount = aggregate.prNumbers.length;

    if (distinctPrCount < RECURRENCE_THRESHOLD) continue;
    if (coveredClass(findingClass)) continue;
    if (suppressedClass(findingClass, distinctPrCount)) continue;

    candidates.push({
      area_tags: aggregate.areaTags,
      distinct_pr_count: distinctPrCount,
      finding_class: findingClass,
      pr_numbers: aggregate.prNumbers,
      severity_max: aggregate.severityMax,
    });
  }

  return {
    candidate_count: candidates.length,
    candidates,
    window_days: windowDays,
  };
};

/**
 * The set of classes with qualifying recurrence evidence (>= threshold distinct
 * PRs at countable severity) in the window, before any suppression/coverage
 * filtering. The ledger-prune pass consumes this so it can drop decline entries
 * whose class no longer recurs.
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
