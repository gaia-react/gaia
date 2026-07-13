import type {MentorshipEvent} from '../reader.js';
/**
 * Intent-clarity-gap pattern detector.
 *
 * Source events:
 *   - `spec_amended`           : amendment_rate signal
 *   - `time_to_resolved_spec`  : question-utilization signal (auto-mode rows
 *                                excluded entirely, see below)
 *
 * Per area_tag composite:
 *   amended_rate      = spec_amended_count_in_area / total_specs_closed_in_area
 *   avg_q_count       = mean(question_count over time_to_resolved_spec for area),
 *                       reported raw, human-interpretable
 *   normalized_q_count = (question_count / question_ceiling) * 5, so a
 *                       session's contribution is expressed as utilization of
 *                       its own ceiling rather than a raw count. A row with no
 *                       `question_ceiling` (every row written before the field
 *                       existed) reads as ceiling 5.
 *   avg_normalized_q_count = mean(normalized_q_count over time_to_resolved_spec
 *                       for area); this is what strength reads
 *   strength = min(1, amended_rate/0.20 * 0.6 + avg_normalized_q_count/15 * 0.4)
 *
 * Threshold to fire: strength ≥ 0.5 AND
 *   (spec_amended_count + time_to_resolved_spec_count) ≥ 10.
 *
 * `time_to_resolved_spec` events carrying `auto: true` are excluded from
 * every accumulator: an auto-mode run answers its own Socratic questions
 * under its own ceiling, and this pattern's remedy (coach the human's
 * question phase) has no meaning for an agent interrogating itself. An
 * amendment to an auto-authored spec buckets under `_unknown` and is
 * dropped rather than inflating a human area's `amended_rate`.
 *
 * `spec_amended` events do not carry `area_tags` directly. They are
 * attributed to whichever areas the same spec_id was tagged with by its
 * `time_to_resolved_spec` event in the window. Specs with no
 * time_to_resolved_spec event in the window bucket under `_unknown`; a
 * sentinel that is dropped from the detector output entirely, so it can
 * never reach the firing threshold or surface in coaching text.
 */
import {
  AMENDED_RATE_TARGET,
  MIN_SAMPLE_COUNT,
  QUESTION_COUNT_TARGET,
  STRENGTH_THRESHOLD,
} from '../strength.js';
import {buildResult} from './rate-helpers.js';
import type {DetectArgs, PatternResult} from './types.js';

const UNKNOWN_AREA = '_unknown';

/**
 * The question ceiling every `time_to_resolved_spec` row on disk was emitted
 * under, and therefore the ceiling `QUESTION_COUNT_TARGET` is calibrated
 * against. It does two jobs, and it is the same number for both for the same
 * reason:
 *
 *   1. A row with no `question_ceiling` (every row written before the field
 *      existed) is read as a 5-ceiling row.
 *   2. A row's question count is rescaled to its 5-ceiling equivalent before
 *      the target applies, so what drives the signal is how much of the
 *      session's budget was spent, not the raw count.
 *
 * Job 2 is the load-bearing one. This pattern's remedy adaptation tells the
 * loop to lengthen its question phase, so a strength that rose with the
 * ceiling would close a feedback loop on itself. Normalizing on utilization
 * opens it: a session that spends 8 of a 10-question budget and one that
 * spends 4 of a 5-question budget carry the same signal and score the same.
 */
const BASELINE_QUESTION_CEILING = 5;

type AreaStats = {
  amendedCount: number;
  /** Distinct spec IDs *closed* in the area: the amended_rate denominator. */
  closedSpecIds: Set<string>;
  /** Counts rescaled to the baseline ceiling. Drives strength. */
  normalizedQuestionCounts: number[];
  /** Raw counts. Reported as `avg_question_count`, human-interpretable. */
  questionCounts: number[];
  ttrCount: number;
};

const ensureArea = (index: Map<string, AreaStats>, area: string): AreaStats => {
  const existing = index.get(area);

  if (existing !== undefined) return existing;
  const fresh: AreaStats = {
    amendedCount: 0,
    closedSpecIds: new Set(),
    normalizedQuestionCounts: [],
    questionCounts: [],
    ttrCount: 0,
  };
  index.set(area, fresh);

  return fresh;
};

const stringFieldOrUndefined = (
  payload: unknown,
  key: string
): string | undefined => {
  if (payload === null || typeof payload !== 'object') return undefined;
  const candidate = (payload as Record<string, unknown>)[key];

  return typeof candidate === 'string' ? candidate : undefined;
};

const numberField = (payload: unknown, key: string): number => {
  if (payload === null || typeof payload !== 'object') return 0;
  const candidate = (payload as Record<string, unknown>)[key];

  // `question_count` is a count: only finite, non-negative numbers are
  // valid. Negative / NaN / Infinity values coerce to 0 so a single
  // malformed event cannot poison the per-area mean.
  return (
      typeof candidate === 'number' &&
        Number.isFinite(candidate) &&
        candidate >= 0
    ) ?
      candidate
    : 0;
};

const isAutoEvent = (payload: unknown): boolean => {
  if (payload === null || typeof payload !== 'object') return false;

  return (payload as Record<string, unknown>).auto === true;
};

const questionCeilingField = (payload: unknown): number => {
  if (payload === null || typeof payload !== 'object') {
    return BASELINE_QUESTION_CEILING;
  }
  const candidate = (payload as Record<string, unknown>).question_ceiling;

  // The ceiling is a divisor. Zero, negative, NaN, and non-finite values would
  // poison the ratio, so anything that is not a positive finite number falls
  // back to the baseline rather than being divided by.
  return (
      typeof candidate === 'number' &&
        Number.isFinite(candidate) &&
        candidate > 0
    ) ?
      candidate
    : BASELINE_QUESTION_CEILING;
};

const arrayStringField = (payload: unknown, key: string): readonly string[] => {
  if (payload === null || typeof payload !== 'object') return [];
  const candidate = (payload as Record<string, unknown>)[key];

  return Array.isArray(candidate) ?
      candidate.filter(
        (entry): entry is string =>
          typeof entry === 'string' && entry.length > 0
      )
    : [];
};

const buildSpecAreaIndex = (
  events: readonly MentorshipEvent[]
): Map<string, readonly string[]> => {
  const map = new Map<string, readonly string[]>();
  const ttrEvents = events.filter(
    (event) =>
      event.event_type === 'time_to_resolved_spec' &&
      !isAutoEvent(event.payload)
  );

  for (const event of ttrEvents) {
    const specId = stringFieldOrUndefined(event.payload, 'spec_id');
    const areaTags = arrayStringField(event.payload, 'area_tags');

    if (specId !== undefined && areaTags.length > 0) {
      map.set(specId, areaTags);
    }
  }

  return map;
};

const accumulateTimeToResolved = (
  event: MentorshipEvent,
  stats: Map<string, AreaStats>
): void => {
  const specId = stringFieldOrUndefined(event.payload, 'spec_id');
  const questionCount = numberField(event.payload, 'question_count');
  const areaTags = arrayStringField(event.payload, 'area_tags');
  const ceiling = questionCeilingField(event.payload);
  // Utilization, expressed in baseline-ceiling units so the existing
  // QUESTION_COUNT_TARGET still applies unchanged.
  const normalizedCount = (questionCount / ceiling) * BASELINE_QUESTION_CEILING;

  for (const area of areaTags) {
    const entry = ensureArea(stats, area);
    entry.ttrCount += 1;
    entry.questionCounts.push(questionCount);
    entry.normalizedQuestionCounts.push(normalizedCount);

    // A time_to_resolved_spec event represents a closed spec; its ID is
    // the only thing that belongs in the amended_rate denominator.
    if (specId !== undefined) entry.closedSpecIds.add(specId);
  }
};

const accumulateSpecAmended = (
  event: MentorshipEvent,
  stats: Map<string, AreaStats>,
  specAreaIndex: Map<string, readonly string[]>
): void => {
  const specId = stringFieldOrUndefined(event.payload, 'spec_id');
  const areaTags =
    specId === undefined ? [] : (specAreaIndex.get(specId) ?? []);
  const targetAreas = areaTags.length === 0 ? [UNKNOWN_AREA] : areaTags;

  for (const area of targetAreas) {
    const entry = ensureArea(stats, area);
    entry.amendedCount += 1;
    // Amended spec IDs are deliberately NOT added to `closedSpecIds`: the
    // amended_rate denominator must be closed specs only. Mixing amended
    // IDs in inflates the denominator when an amended spec has no
    // time_to_resolved_spec event in the window.
  }
};

const buildStats = (
  events: readonly MentorshipEvent[]
): Map<string, AreaStats> => {
  const specAreaIndex = buildSpecAreaIndex(events);
  const stats = new Map<string, AreaStats>();

  for (const event of events) {
    if (event.event_type === 'time_to_resolved_spec') {
      // Auto-mode runs answer their own Socratic questions under their own
      // question ceiling. Pooling them with human-driven runs would mix two
      // ceiling regimes into one mean, and the pattern's remedy (coach the
      // human's question phase) has no meaning for an agent interrogating
      // itself. Excluded from every accumulator.
      if (!isAutoEvent(event.payload)) accumulateTimeToResolved(event, stats);
    } else if (event.event_type === 'spec_amended') {
      accumulateSpecAmended(event, stats, specAreaIndex);
    }
  }

  return stats;
};

const mean = (values: readonly number[]): number => {
  if (values.length === 0) return 0;
  let total = 0;

  for (const value of values) total += value;

  return total / values.length;
};

const buildAreaResult = (area: string, stats: AreaStats): PatternResult => {
  const sample = stats.amendedCount + stats.ttrCount;
  const closedSpecs = stats.closedSpecIds.size;
  // A spec amended more than once contributes >1 to `amendedCount` while its
  // closed-spec ID contributes only 1 to the denominator, so the raw ratio
  // can exceed 1. Clamp at the source; the `amended_rate` component value
  // must be a bounded rate in [0, 1].
  const amendedRate =
    closedSpecs === 0 ? 0 : Math.min(1, stats.amendedCount / closedSpecs);
  const avgQ = mean(stats.questionCounts);
  const averageNormalizedQuestions = mean(stats.normalizedQuestionCounts);
  const fires = sample >= MIN_SAMPLE_COUNT;
  const strength =
    fires ?
      Math.min(
        1,
        (amendedRate / AMENDED_RATE_TARGET) * 0.6 +
          (averageNormalizedQuestions / QUESTION_COUNT_TARGET) * 0.4
      )
    : null;
  const components = [
    {metric: 'amended_count', value: stats.amendedCount},
    {metric: 'ttr_count', value: stats.ttrCount},
    {metric: 'amended_rate', value: amendedRate},
    {metric: 'avg_question_count', value: avgQ},
    {
      metric: 'avg_normalized_question_count',
      value: averageNormalizedQuestions,
    },
    ...(fires ?
      [{metric: 'strength_threshold', value: STRENGTH_THRESHOLD}]
    : []),
  ];

  return buildResult({
    area,
    components,
    patternId: 'intent_clarity_gap',
    sample,
    strength,
  });
};

export const detectIntentClarityGap = (args: DetectArgs): PatternResult[] => {
  const stats = buildStats(args.events);
  const results: PatternResult[] = [];

  for (const [area, entry] of stats) {
    // `_unknown` is a sentinel for specs that could not be attributed to a
    // real area, not an area itself. Excluded from threshold evaluation and
    // coaching output so it can never surface as "...working in _unknown".
    if (area !== UNKNOWN_AREA) results.push(buildAreaResult(area, entry));
  }

  return results;
};
