/**
 * The tech-debt filer's three refusal arms, reproduced so the tally never
 * offers a residual the filer would refuse to file. Offering one anyway is a
 * livelock: the human answers the same question forever, promotion always
 * declines as a duplicate, and nothing is ever recorded.
 *
 * Arms 1 and 2 read issue-body keys through `parseWrappedKeys`, never
 * `parseKey`: the filer's own grammar anchors on the wrapped
 * `<!-- gaia-debt-key:` opener, does not require the `v1` token, and reads a
 * path containing a space, all of which `parseKey`'s stricter gate grammar
 * would refuse. Suppression must agree with the filer on its own leniencies,
 * not with the merge gate.
 */
import {escapeRegExp} from '../util/escape-regexp.js';
import type {IssueRecord} from './corpus.js';
import {parseWrappedKeys, sameCoordinate} from './key.js';

export type IssueArmVerdict =
  | {previously_promoted_issue: null | number; suppressed: false}
  | {suppressed: true};

// Arm 3: a bare `<path>:<line>` mention in an open issue body, anchored so
// `foo.ts:4` does not match a sibling `foo.ts:42`.
const bareMentionMatches = (
  body: string,
  candidate: {line: number; path: string}
): boolean =>
  new RegExp(
    String.raw`${escapeRegExp(candidate.path)}:${candidate.line}(?!\d)`
  ).test(body);

const isDeclined = (issue: IssueRecord): boolean =>
  issue.labels.some((label) => label.name === 'wontfix') ||
  issue.stateReason === 'NOT_PLANNED';

export const evaluateIssueArms = (
  issues: readonly IssueRecord[],
  candidate: {line: number; path: string}
): IssueArmVerdict => {
  let promotedIssue: null | number = null;

  for (const issue of issues) {
    const keys = parseWrappedKeys(issue.body);
    const keyMatches = keys.some((key) => sameCoordinate(key, candidate));

    if (keyMatches) {
      if (issue.state === 'OPEN') return {suppressed: true}; // arm 1

      if (isDeclined(issue)) return {suppressed: true}; // arm 2

      // Closed as completed: not suppressed, but flagged for RD-003's
      // re-offer-with-dismiss-as-default triage.
      promotedIssue = issue.number;
    }
  }

  for (const issue of issues) {
    if (issue.state === 'OPEN' && bareMentionMatches(issue.body, candidate)) {
      return {suppressed: true}; // arm 3
    }
  }

  return {previously_promoted_issue: promotedIssue, suppressed: false};
};
