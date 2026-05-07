import type {MentorshipEvent} from '../reader.js';
/**
 * Intent-clarity-gap pattern detector.
 *
 * Source events:
 *   - `spec_amended`           — amendment_rate signal
 *   - `time_to_resolved_spec`  — question_count signal
 *
 * Per area_tag composite:
 *   amended_rate = spec_amended_count_in_area / total_specs_closed_in_area
 *   avg_q_count  = mean(question_count over time_to_resolved_spec for area)
 *   strength = min(1, amended_rate/0.20 * 0.6 + avg_q_count/15 * 0.4)
 *
 * Threshold to fire: strength ≥ 0.5 AND
 *   (spec_amended_count + time_to_resolved_spec_count) ≥ 10.
 *
 * `spec_amended` events do not carry `area_tags` directly. They are
 * attributed to whichever areas the same spec_id was tagged with by its
 * `time_to_resolved_spec` event in the window. Specs with no
 * time_to_resolved_spec event in the window bucket under `_unknown` —
 * which never accumulates to threshold and stays below the sample minimum.
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

type AreaStats = {
  amendedCount: number;
  questionCounts: number[];
  specIds: Set<string>;
  ttrCount: number;
};

const ensureArea = (index: Map<string, AreaStats>, area: string): AreaStats => {
  const existing = index.get(area);

  if (existing !== undefined) return existing;
  const fresh: AreaStats = {
    amendedCount: 0,
    questionCounts: [],
    specIds: new Set(),
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

  return typeof candidate === 'number' ? candidate : 0;
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
    (event) => event.event_type === 'time_to_resolved_spec'
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

  for (const area of areaTags) {
    const entry = ensureArea(stats, area);
    entry.ttrCount += 1;
    entry.questionCounts.push(questionCount);

    if (specId !== undefined) entry.specIds.add(specId);
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

    if (specId !== undefined) entry.specIds.add(specId);
  }
};

const buildStats = (
  events: readonly MentorshipEvent[]
): Map<string, AreaStats> => {
  const specAreaIndex = buildSpecAreaIndex(events);
  const stats = new Map<string, AreaStats>();

  for (const event of events) {
    if (event.event_type === 'time_to_resolved_spec') {
      accumulateTimeToResolved(event, stats);
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
  const totalSpecs = stats.specIds.size;
  const amendedRate = totalSpecs === 0 ? 0 : stats.amendedCount / totalSpecs;
  const avgQ = mean(stats.questionCounts);
  const fires = sample >= MIN_SAMPLE_COUNT;
  const strength =
    fires ?
      Math.min(
        1,
        (amendedRate / AMENDED_RATE_TARGET) * 0.6 +
          (avgQ / QUESTION_COUNT_TARGET) * 0.4
      )
    : null;
  const components = [
    {metric: 'amended_count', value: stats.amendedCount},
    {metric: 'ttr_count', value: stats.ttrCount},
    {metric: 'amended_rate', value: amendedRate},
    {metric: 'avg_question_count', value: avgQ},
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
    results.push(buildAreaResult(area, entry));
  }

  return results;
};
