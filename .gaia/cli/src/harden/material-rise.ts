/**
 * The only threshold definitions for "has a finding class materially risen",
 * shared by trigger evaluation (`harden-tally`) and decline re-surface
 * (`harden-ledger is-suppressed`). Fixed by design; changing a value here is
 * an ask-first decision, not a tuning knob.
 *
 * `TALLY_SCHEMA_VERSION` is bumped whenever the tally's counting semantics
 * change: the window, the recurrence threshold, the audited-PR predicate,
 * the per-auditor merge, or which findings blocks count as parseable.
 */
export const RISE_RATIO_NUM = 5;

export const RISE_RATIO_DEN = 4;

export const RISE_MIN_PR_DELTA = 3;

export const MIN_TRUSTED_AUDITED_PRS = 20;

export const TALLY_SCHEMA_VERSION = 1;

export type MaterialRiseArgs = {
  baseAuditedPrCount: number;
  baseCount: number;
  liveAuditedPrCount: number;
  liveCount: number;
};

/**
 * True when a class's count has risen materially between a base snapshot and
 * the live tally. Integer arithmetic only: no division, no stored float
 * shares. When either side's audited-PR denominator is below
 * `MIN_TRUSTED_AUDITED_PRS`, the comparison falls back to a raw-count ratio
 * (too few audited PRs to trust a share); otherwise it compares shares by
 * integer cross-multiplication. The `RISE_MIN_PR_DELTA` floor applies in
 * both branches, so a small live-PR sample can never trip the rule on ratio
 * alone.
 */
export const isMaterialRise = ({
  baseAuditedPrCount,
  baseCount,
  liveAuditedPrCount,
  liveCount,
}: MaterialRiseArgs): boolean => {
  if (liveCount - baseCount < RISE_MIN_PR_DELTA) return false;

  if (
    baseAuditedPrCount < MIN_TRUSTED_AUDITED_PRS ||
    liveAuditedPrCount < MIN_TRUSTED_AUDITED_PRS
  ) {
    return liveCount * RISE_RATIO_DEN >= RISE_RATIO_NUM * baseCount;
  }

  return (
    liveCount * baseAuditedPrCount * RISE_RATIO_DEN >=
    RISE_RATIO_NUM * baseCount * liveAuditedPrCount
  );
};
