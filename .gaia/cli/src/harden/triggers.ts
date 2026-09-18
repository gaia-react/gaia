/**
 * Pure trigger evaluation for the `/gaia-harden` statusline nudge: compares
 * the live `harden-tally` result against the machine-local review snapshot
 * and names what changed since the last completed review. No I/O; the caller
 * supplies the live tally fields and the parsed snapshot (`null` when absent
 * or malformed).
 *
 * Every rise comparison goes through the one shared `isMaterialRise`
 * (`material-rise.ts`); this module never reads a snapshot's stored `share`
 * value or the ratio constants directly.
 */
import type {ReviewSnapshot} from '../schemas/review-snapshot.js';
import {isMaterialRise} from './material-rise.js';

export type EvaluateTriggersArgs = {
  live: {
    auditedPrCount: number;
    candidates: readonly {distinct_pr_count: number; finding_class: string}[];
    tallySchemaVersion: number;
    unclassified: null | {distinct_pr_count: number};
  };
  snapshot: null | ReviewSnapshot;
};

export type HardenTrigger =
  | {finding_class: string; type: 'new_class'}
  | {finding_class: string; type: 'rising_class'}
  | {type: 'rising_unclassified'}
  | {type: 'schema_change'};

export const evaluateTriggers = ({
  live,
  snapshot,
}: EvaluateTriggersArgs): HardenTrigger[] => {
  if (snapshot === null) return [];

  // A schema-version mismatch means the tally's counting semantics changed
  // since the snapshot was taken, so every count in it is incomparable: name
  // the mismatch and refuse every other trigger rather than compare stale
  // numbers to fresh ones.
  if (live.tallySchemaVersion !== snapshot.tally_schema_version) {
    return [{type: 'schema_change'}];
  }

  const triggers: HardenTrigger[] = [];

  for (const candidate of live.candidates) {
    const base = snapshot.classes[candidate.finding_class];

    if (base === undefined) {
      triggers.push({
        finding_class: candidate.finding_class,
        type: 'new_class',
      });
    } else {
      const risen = isMaterialRise({
        baseAuditedPrCount: snapshot.audited_pr_count,
        baseCount: base.distinct_pr_count,
        liveAuditedPrCount: live.auditedPrCount,
        liveCount: candidate.distinct_pr_count,
      });

      if (risen) {
        triggers.push({
          finding_class: candidate.finding_class,
          type: 'rising_class',
        });
      }
    }
  }

  if (live.unclassified !== null) {
    const baseUnclassified = snapshot.unclassified;
    const risen =
      baseUnclassified === null ||
      isMaterialRise({
        baseAuditedPrCount: snapshot.audited_pr_count,
        baseCount: baseUnclassified.distinct_pr_count,
        liveAuditedPrCount: live.auditedPrCount,
        liveCount: live.unclassified.distinct_pr_count,
      });

    if (risen) triggers.push({type: 'rising_unclassified'});
  }

  return triggers;
};
