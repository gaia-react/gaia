import type {PatternId} from '../adaptation-map.js';
/**
 * Shared helpers for rate-based pattern detectors (articulation_gap +
 * knowledge_gap). Both compute matching_events / distinct_tasks_in_area
 * over a rolling window; the only thing that differs is the event filter.
 */
import type {MentorshipEvent} from '../reader.js';
import type {PatternResult} from './types.js';

const eventTaskId = (event: MentorshipEvent): string | undefined => {
  const candidate = event.payload as {task_id?: unknown};

  return typeof candidate.task_id === 'string' && candidate.task_id.length > 0 ?
      candidate.task_id
    : undefined;
};

const eventAreaTags = (event: MentorshipEvent): readonly string[] => {
  const candidate = event.payload as {area_tags?: unknown};

  return Array.isArray(candidate.area_tags) ?
      candidate.area_tags.filter(
        (entry): entry is string =>
          typeof entry === 'string' && entry.length > 0
      )
    : [];
};

/**
 * Walk every event in the window and return a map area_tag -> Set<task_id>.
 * The `task_id` set is the denominator for the per-area rate computation.
 */
export const buildAreaIndex = (
  events: readonly MentorshipEvent[]
): Map<string, Set<string>> => {
  const index = new Map<string, Set<string>>();

  for (const event of events) {
    const taskId = eventTaskId(event);

    for (const area of eventAreaTags(event)) {
      const set = index.get(area) ?? new Set<string>();

      if (taskId !== undefined) set.add(taskId);
      index.set(area, set);
    }
  }

  return index;
};

/**
 * Walk every event matching `predicate` and return a map area_tag -> count.
 * The matching count is the numerator (sample_count) for rate computation.
 */
export const matchedEventsByArea = (
  events: readonly MentorshipEvent[],
  predicate: (event: MentorshipEvent) => boolean
): Map<string, number> => {
  const matches = new Map<string, number>();

  for (const event of events.filter((entry) => predicate(entry))) {
    for (const area of eventAreaTags(event)) {
      matches.set(area, (matches.get(area) ?? 0) + 1);
    }
  }

  return matches;
};

type BuildResultArgs = {
  area: string;
  components: PatternResult['components'];
  patternId: PatternId;
  sample: number;
  strength: null | number;
};

export const buildResult = (args: BuildResultArgs): PatternResult => ({
  area_tag: args.area,
  components: args.components,
  pattern_id: args.patternId,
  sample_count: args.sample,
  strength: args.strength,
});
