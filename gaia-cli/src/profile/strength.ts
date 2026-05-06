/**
 * Rolling-window strength helpers shared by the three pattern detectors.
 *
 * Constants:
 *   MIN_SAMPLE_COUNT     — events required before a pattern can fire
 *   STRENGTH_THRESHOLD   — minimum strength for a pattern to fire (and stay active)
 *   RATE_TARGET          — saturation rate for rate-based detectors (30%)
 *   AMENDED_RATE_TARGET  — saturation rate for spec_amended in intent-clarity gap
 *   QUESTION_COUNT_TARGET — saturation Q-count for time_to_resolved_spec
 *   FADE_IMPROVEMENT_FULL — improvement (delta in metric) at which fade reaches 1.0
 *   FLAKE_DOWNWEIGHT     — multiplier applied to flake_suspected uat_fail events (UAT-032)
 *
 * Per SPEC §"deferred clarifications" the constants are implementation
 * latitude, tunable from real-data feedback before May 12 public launch.
 */

export const MIN_SAMPLE_COUNT = 10;

export const STRENGTH_THRESHOLD = 0.5;

export const RATE_TARGET = 0.3;

export const AMENDED_RATE_TARGET = 0.2;

export const QUESTION_COUNT_TARGET = 15;

export const FADE_IMPROVEMENT_FULL = 0.5;

export const FLAKE_DOWNWEIGHT = 0.25;

/**
 * Saturating rate→strength mapping. `min(1, rate / target)`.
 */
export const rateStrength = (rate: number, target: number): number => {
  if (target <= 0) return 0;
  if (rate <= 0) return 0;

  return Math.min(1, rate / target);
};

/**
 * Linear fade: `max(0, 1 - improvement / FADE_IMPROVEMENT_FULL)`.
 *
 * `improvement` is positive when the metric is moving in the desired direction
 * (e.g. needs_context_returned rate dropping). 0 → no fade. ≥0.5 → full fade.
 *
 * UAT-031: an articulation-gap adaptation active for 3 weeks where the user's
 * needs_context_returned rate dropped from 0.40 to 0.18 → improvement 0.22 →
 * fade_factor ≈ 0.56 → adaptation may move to faded once new strength × fade
 * drops below the firing threshold.
 */
export const fadeFactor = (improvement: number): number => {
  if (improvement <= 0) return 1;
  if (improvement >= FADE_IMPROVEMENT_FULL) return 0;

  return Math.max(0, 1 - improvement / FADE_IMPROVEMENT_FULL);
};

/**
 * UAT-032: flake_suspected uat_fail events are downweighted by 0.25.
 * Used by future patterns that aggregate uat_fail rates; not exercised
 * directly by the v1 articulation/knowledge/intent-clarity detectors.
 * Lands here as a shared utility for Sequel features.
 */
export const weightForUatFail = (failure_class: string): number =>
  failure_class === 'flake_suspected' ? FLAKE_DOWNWEIGHT : 1;
