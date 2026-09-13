/**
 * The pure candidate-assembly core (DP-009, frozen order): attributes ->
 * validates (already split into `entries`/`malformed` by `attribution.ts`)
 * -> issue-arm suppression -> store suppression -> counts -> order/cursor/cap
 * -> resolve the emitted batch. No I/O: the caller supplies the attributed
 * entries, the issue corpus, the store records, and a `resolve` callback
 * whose behavior (a real fetch, or `unresolvedResolver`) encodes the
 * `--count-only` degradation entirely at the call site.
 *
 * The order below is fixed by `plan/README.md`'s "Resolution budget and
 * ordering" section and may not be reordered: `aged_candidate_count` is
 * counted before the cap so the statusline nudge's five-candidate threshold
 * stays reachable at any legal cap, and resolution happens only for a
 * store-coordinate match (step 4) and the emitted batch (step 7), never for
 * the full survivor population.
 */
import type {
  AttributionResult,
  MalformedKey,
  ResidueDisposition,
} from './attribution.js';
import type {IssueRecord} from './corpus.js';
import type {ResolveCandidate, ResolvedCandidate} from './resolve.js';
import {hasCoordinateRecord, storeSuppression} from './store.js';
import type {StoreRecord, SuppressionMode} from './store.js';
import {evaluateIssueArms} from './suppression.js';
import {encodeToken} from './token.js';

const DAY_MS = 24 * 60 * 60 * 1000;
const AGE_THRESHOLD_DAYS = 30;

export type CandidateInputPr = {
  attribution: AttributionResult;
  headRefOid: string;
  mergedAt: string;
  number: number;
};

export type ComputeCandidatesArgs = {
  cap: number;
  cursor: null | {line: number; path: string; pr_number: number};
  issues: readonly IssueRecord[];
  keepWindowDays: number;
  now: Date;
  prs: readonly CandidateInputPr[];
  resolve: (candidate: ResolveCandidate) => ResolvedCandidate;
  storeRecords: readonly StoreRecord[];
  suppressionMode: SuppressionMode;
};

export type ComputeCandidatesResult = {
  aged_candidate_count: number;
  candidate_count: number;
  candidates: EmittedCandidate[];
  malformed: EmittedMalformed[];
  remaining_count: number;
  total_keyed_count: number;
};

export type EmittedCandidate = {
  age_days: number;
  class: string;
  cursor_token: string;
  disposition: ResidueDisposition;
  failure_mode: string;
  head_sha: string;
  line: number;
  merged_at: string;
  path: string;
  pr_number: number;
  previously_promoted_issue: null | number;
  raw_key: string;
  resolution: ResolvedCandidate['resolution'];
  resolved_line_text: string;
};

export type EmittedMalformed = MalformedKey & {pr_number: number};

type AttributedCandidate = {
  class: string;
  disposition: ResidueDisposition;
  failure_mode: string;
  line: number;
  path: string;
  pr: CandidateInputPr;
  raw_key: string;
};

type OpenCandidate = {
  class: string;
  disposition: ResidueDisposition;
  failure_mode: string;
  headRefOid: string;
  line: number;
  mergedAt: string;
  path: string;
  previously_promoted_issue: null | number;
  prNumber: number;
  raw_key: string;
};

type ResolveCached = (candidate: ResolveCandidate) => ResolvedCandidate;

const ageDays = (mergedAt: string, now: Date): number =>
  Math.floor((now.getTime() - Date.parse(mergedAt)) / DAY_MS);

// Steps 1-2: attribution and key validation already happened upstream
// (`attribution.ts` splits a body into `entries` and `malformed`); this just
// flattens both across the window, tagging `malformed` with its
// pull-request number.
const collectAttributed = (
  prs: readonly CandidateInputPr[]
): {
  attributed: AttributedCandidate[];
  malformed: EmittedMalformed[];
  totalKeyedCount: number;
} => {
  const malformed: EmittedMalformed[] = [];
  const attributed: AttributedCandidate[] = [];
  let totalKeyedCount = 0;

  for (const pr of prs) {
    totalKeyedCount += pr.attribution.entries.length;

    for (const entry of pr.attribution.entries) {
      attributed.push({
        class: entry.key.class,
        disposition: entry.disposition,
        failure_mode: entry.failure_mode,
        line: entry.key.line,
        path: entry.key.path,
        pr,
        raw_key: entry.raw_key,
      });
    }

    for (const bad of pr.attribution.malformed) {
      malformed.push({...bad, pr_number: pr.number});
    }
  }

  return {attributed, malformed, totalKeyedCount};
};

// Step 3: issue-arm suppression, no resolution.
const applyIssueArmSuppression = (
  attributed: readonly AttributedCandidate[],
  issues: readonly IssueRecord[]
): OpenCandidate[] =>
  attributed.flatMap((candidate) => {
    const verdict = evaluateIssueArms(issues, candidate);

    if (verdict.suppressed) return [];

    return [
      {
        class: candidate.class,
        disposition: candidate.disposition,
        failure_mode: candidate.failure_mode,
        headRefOid: candidate.pr.headRefOid,
        line: candidate.line,
        mergedAt: candidate.pr.mergedAt,
        path: candidate.path,
        previously_promoted_issue: verdict.previously_promoted_issue,
        prNumber: candidate.pr.number,
        raw_key: candidate.raw_key,
      },
    ];
  });

const makeResolveCached = (
  resolve: (candidate: ResolveCandidate) => ResolvedCandidate
): ResolveCached => {
  const cache = new Map<string, ResolvedCandidate>();

  return (candidate) => {
    const key = `${candidate.headSha}:${candidate.path}:${candidate.line}`;
    const cached = cache.get(key);

    if (cached !== undefined) return cached;

    const resolved = resolve(candidate);

    cache.set(key, resolved);

    return resolved;
  };
};

// Step 4: store suppression. `hasCoordinateRecord` gates resolution: only a
// candidate with a coordinate match needs it, and only under
// `'content-bound'`.
const applyStoreSuppression = (
  survivors: readonly OpenCandidate[],
  args: ComputeCandidatesArgs,
  resolveCached: ResolveCached
): OpenCandidate[] =>
  survivors.filter((candidate) => {
    const hasRecord = hasCoordinateRecord(args.storeRecords, {
      line: candidate.line,
      path: candidate.path,
    });

    if (!hasRecord) return true;

    const citedLineText =
      args.suppressionMode === 'content-bound' ?
        resolveCached({
          headSha: candidate.headRefOid,
          line: candidate.line,
          path: candidate.path,
          prNumber: candidate.prNumber,
        }).resolved_line_text
      : '';

    const verdict = storeSuppression(
      args.storeRecords,
      {
        cited_line_text: citedLineText,
        line: candidate.line,
        path: candidate.path,
      },
      args.now,
      args.keepWindowDays,
      args.suppressionMode
    );

    return !verdict.suppressed;
  });

// Step 6: total, stable order; skip past the cursor; slice to the cap.
const orderCandidates = (open: readonly OpenCandidate[]): OpenCandidate[] =>
  open.toSorted((a, b) => {
    const byMergedAt = Date.parse(a.mergedAt) - Date.parse(b.mergedAt);

    if (byMergedAt !== 0) return byMergedAt;

    const byPr = a.prNumber - b.prNumber;

    return byPr === 0 ? a.line - b.line : byPr;
  });

const skipPastCursor = (
  ordered: readonly OpenCandidate[],
  cursor: ComputeCandidatesArgs['cursor']
): number => {
  if (cursor === null) return 0;

  const cursorIndex = ordered.findIndex(
    (candidate) =>
      candidate.prNumber === cursor.pr_number &&
      candidate.path === cursor.path &&
      candidate.line === cursor.line
  );

  return cursorIndex === -1 ? 0 : cursorIndex + 1;
};

// Step 7: resolve the emitted batch only.
const buildEmittedCandidates = (
  batch: readonly OpenCandidate[],
  now: Date,
  resolveCached: ResolveCached
): EmittedCandidate[] =>
  batch.map((candidate) => {
    const resolved = resolveCached({
      headSha: candidate.headRefOid,
      line: candidate.line,
      path: candidate.path,
      prNumber: candidate.prNumber,
    });

    return {
      age_days: ageDays(candidate.mergedAt, now),
      class: candidate.class,
      cursor_token: encodeToken({
        line: candidate.line,
        path: candidate.path,
        pr_number: candidate.prNumber,
      }),
      disposition: candidate.disposition,
      failure_mode: candidate.failure_mode,
      head_sha: candidate.headRefOid,
      line: candidate.line,
      merged_at: candidate.mergedAt,
      path: candidate.path,
      pr_number: candidate.prNumber,
      previously_promoted_issue: candidate.previously_promoted_issue,
      raw_key: candidate.raw_key,
      resolution: resolved.resolution,
      resolved_line_text: resolved.resolved_line_text,
    };
  });

export const computeCandidates = (
  args: ComputeCandidatesArgs
): ComputeCandidatesResult => {
  const {attributed, malformed, totalKeyedCount} = collectAttributed(args.prs);
  const survivors = applyIssueArmSuppression(attributed, args.issues);
  const resolveCached = makeResolveCached(args.resolve);
  const open = applyStoreSuppression(survivors, args, resolveCached);

  // Step 5: counts over the full post-suppression population, before the
  // cursor skip and before the cap.
  const remainingCount = open.length;
  const agedCandidateCount = open.filter(
    (candidate) => ageDays(candidate.mergedAt, args.now) >= AGE_THRESHOLD_DAYS
  ).length;

  const ordered = orderCandidates(open);
  const startIndex = skipPastCursor(ordered, args.cursor);
  const batch = ordered.slice(startIndex, startIndex + args.cap);
  const candidates = buildEmittedCandidates(batch, args.now, resolveCached);

  return {
    aged_candidate_count: agedCandidateCount,
    candidate_count: candidates.length,
    candidates,
    malformed,
    remaining_count: remainingCount,
    total_keyed_count: totalKeyedCount,
  };
};
