import type {MentorshipEvent} from '../reader.js';
/**
 * Articulation-gap pattern detector.
 *
 * Source events: `needs_context_returned` with
 * `context_request_class === 'unclear_acceptance_criteria'`.
 *
 * Computation:
 *   For each `area_tag`, the rate is
 *     matching_events_in_area / total_distinct_tasks_in_area_window.
 *   Total distinct tasks = unique `task_id` values across ALL event types
 *   that mention the area_tag in the rolling window.
 *
 * Strength: `min(1, rate / 0.30)`.
 *
 * Threshold to fire: strength ≥ 0.5 AND sample_count ≥ 10
 * (sample_count = number of matching events in the area).
 *
 * UAT-030: 30+ matching events clustered in `visual` over 30 days → fires.
 * UAT-029: <10 matching events → strength is null, "below sample threshold".
 */
import {
  MIN_SAMPLE_COUNT,
  RATE_TARGET,
  rateStrength,
  STRENGTH_THRESHOLD,
} from '../strength.js';
import {
  buildAreaIndex,
  buildResult,
  matchedEventsByArea,
} from './rate-helpers.js';
import type {DetectArgs, PatternResult} from './types.js';

const isArticulationGapEvent = (
  event: MentorshipEvent
): event is MentorshipEvent<'needs_context_returned'> =>
  event.event_type === 'needs_context_returned' &&
  (event.payload as {context_request_class?: string}).context_request_class ===
    'unclear_acceptance_criteria';

export const detectArticulationGap = (args: DetectArgs): PatternResult[] => {
  const totals = buildAreaIndex(args.events);
  const matching = matchedEventsByArea(args.events, isArticulationGapEvent);
  const results: PatternResult[] = [];
  const areas = new Set<string>([...totals.keys(), ...matching.keys()]);

  for (const area of areas) {
    const totalTasks = totals.get(area)?.size ?? 0;
    const sample = matching.get(area) ?? 0;
    const rate = totalTasks === 0 ? 0 : sample / totalTasks;
    const fires = sample >= MIN_SAMPLE_COUNT;
    results.push(
      buildResult({
        area,
        components: [
          {metric: 'matching_events', value: sample},
          {metric: 'total_tasks_in_area', value: totalTasks},
          {metric: 'rate', value: rate},
          ...(fires ?
            [{metric: 'strength_threshold', value: STRENGTH_THRESHOLD}]
          : []),
        ],
        patternId: 'articulation_gap',
        sample,
        strength: fires ? rateStrength(rate, RATE_TARGET) : null,
      })
    );
  }

  return results;
};
