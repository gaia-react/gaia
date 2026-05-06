import type {PatternId} from '../adaptation-map.js';
import type {MentorshipEvent} from '../reader.js';

export type DetectArgs = {
  events: readonly MentorshipEvent[];
  windowDays: number;
};

export type Detector = (args: DetectArgs) => PatternResult[];

export type PatternResult = {
  area_tag: string;
  components: {metric: string; value: number}[];
  pattern_id: PatternId;
  sample_count: number;
  // null when sample_count < MIN_SAMPLE_COUNT — UAT-029 "below sample threshold".
  strength: null | number;
};
