/**
 * Pattern detector dispatch. Runs each detector against the same window
 * of events and returns the concatenated results.
 *
 * Each detector returns one PatternResult per area_tag observed for its
 * source events; sample_count < threshold yields strength=null (the
 * "below sample threshold" branch).
 */
import {detectArticulationGap} from './articulation-gap.js';
import {detectIntentClarityGap} from './intent-clarity-gap.js';
import {detectKnowledgeGap} from './knowledge-gap.js';
import type {DetectArgs, Detector, PatternResult} from './types.js';

export {detectArticulationGap} from './articulation-gap.js';

export {detectIntentClarityGap} from './intent-clarity-gap.js';

export {detectKnowledgeGap} from './knowledge-gap.js';

export type {DetectArgs} from './types.js';

export type {Detector} from './types.js';

export type {PatternResult} from './types.js';

const DETECTORS: readonly Detector[] = [
  detectArticulationGap,
  detectKnowledgeGap,
  detectIntentClarityGap,
];

export const runAllPatternDetectors = (args: DetectArgs): PatternResult[] => {
  const all: PatternResult[] = [];

  for (const detector of DETECTORS) {
    all.push(...detector(args));
  }

  return all;
};
