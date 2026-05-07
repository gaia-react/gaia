import type {MentorshipEvent} from '../reader.js';
/**
 * Knowledge-gap pattern detector.
 *
 * Source events: `needs_context_returned` with
 * `context_request_class === 'missing_codebase_knowledge'`.
 *
 * Same shape as articulation-gap; different event filter.
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

const isKnowledgeGapEvent = (
  event: MentorshipEvent
): event is MentorshipEvent<'needs_context_returned'> =>
  event.event_type === 'needs_context_returned' &&
  (event.payload as {context_request_class?: string}).context_request_class ===
    'missing_codebase_knowledge';

export const detectKnowledgeGap = (args: DetectArgs): PatternResult[] => {
  const totals = buildAreaIndex(args.events);
  const matching = matchedEventsByArea(args.events, isKnowledgeGapEvent);
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
        patternId: 'knowledge_gap',
        sample,
        strength: fires ? rateStrength(rate, RATE_TARGET) : null,
      })
    );
  }

  return results;
};
