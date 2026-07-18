/**
 * Deterministic parser for the machine-readable findings block CI (and a local
 * audit run) appends to a PR comment.
 *
 * Shape (frozen by the comment-block contract):
 *
 *   <!-- gaia-harden:findings:start -->
 *   <!--
 *   {"schema":1,"pr_number":N,"auditor":"ci","findings":[
 *     {"finding_class":"...","severity":"warning","area_tags":["..."]}
 *   ]}
 *   -->
 *   <!-- gaia-harden:findings:end -->
 *
 * The JSON payload lives INSIDE an inner HTML comment so it does not render. The
 * parser locates the sentinels, strips the inner comment framing, and
 * `JSON.parse`s the payload. Anything malformed yields `null` (no block) so the
 * caller treats the PR as carrying no countable findings rather than crashing
 * the refresher.
 */
const START_SENTINEL = '<!-- gaia-harden:findings:start -->';
const END_SENTINEL = '<!-- gaia-harden:findings:end -->';

export type ParsedFinding = {
  area_tags: string[];
  finding_class: string;
  severity: 'error' | 'suggestion' | 'warning';
};

/**
 * A parsed block: the findings plus the producer that posted them. `auditor`
 * is read verbatim from the payload's `auditor` field when it is a non-empty
 * string; a missing, empty, or non-string `auditor` normalizes to `''`, the
 * shared "anonymous producer" bucket (see `recordFromGhPr` in `tally.ts`,
 * which keys its per-auditor merge on this field).
 */
export type ParsedFindingsBlock = {
  auditor: string;
  findings: ParsedFinding[];
};

/**
 * The one accepted severity set. `severity-map.ts`'s `SEVERITY_BY_GRADING`
 * maps every agent grading onto it; it is the one source and no test may
 * re-declare it (README FC-7).
 */
export const SEVERITIES = new Set(['error', 'suggestion', 'warning']);

export type OnReject = (reason: RejectReason, detail: string) => void;

export type RejectReason = 'area_tags' | 'finding_class' | 'severity' | 'shape';

// Stringifies an offending value for the rejection message. Strings print
// as-is; `undefined` (a missing property) prints literally; anything else
// falls back to JSON.
const describeToken = (value: unknown): string => {
  if (typeof value === 'string') return value;
  if (value === undefined) return 'undefined';

  return JSON.stringify(value);
};

const defaultOnReject: OnReject = (reason, detail) => {
  process.stderr.write(
    `parse-findings-block: dropped a finding (${reason}): unaccepted token "${detail}"\n`
  );
};

const parseFinding = (
  value: unknown,
  onReject: OnReject
): null | ParsedFinding => {
  if (typeof value !== 'object' || value === null) {
    onReject('shape', describeToken(value));

    return null;
  }
  const v = value as Record<string, unknown>;

  if (typeof v.finding_class !== 'string' || v.finding_class.length === 0) {
    onReject('finding_class', describeToken(v.finding_class));

    return null;
  }

  if (typeof v.severity !== 'string' || !SEVERITIES.has(v.severity)) {
    onReject('severity', describeToken(v.severity));

    return null;
  }

  if (
    !Array.isArray(v.area_tags) ||
    !v.area_tags.every((tag): tag is string => typeof tag === 'string')
  ) {
    onReject('area_tags', describeToken(v.area_tags));

    return null;
  }

  return {
    area_tags: v.area_tags,
    finding_class: v.finding_class,
    severity: v.severity as ParsedFinding['severity'],
  };
};

/**
 * Returns `{auditor, findings}` for a parseable block, or `null` when no
 * parseable block is present. `findings` is `[]` for an explicit empty block.
 * `auditor` is the payload's `auditor` field verbatim when it is a non-empty
 * string; a missing, empty, or non-string `auditor` normalizes to `''` (see
 * `ParsedFindingsBlock`). `onReject` (default: a stderr writer) fires once per
 * dropped finding, bad severity, missing/empty finding_class, malformed
 * area_tags, or a non-object entry, naming the offending token. It never
 * fires on a `null` return: that means "no parseable block" (no sentinels, no
 * inner comment, bad JSON, `findings` not an array), a different thing from a
 * dropped finding, and the overwhelmingly common case of a comment carrying
 * no block at all must stay silent.
 */
export const parseFindingsBlock = (
  body: string,
  onReject: OnReject = defaultOnReject
): null | ParsedFindingsBlock => {
  const startIndex = body.indexOf(START_SENTINEL);

  if (startIndex === -1) return null;

  const endIndex = body.indexOf(END_SENTINEL, startIndex);

  if (endIndex === -1) return null;

  const between = body.slice(startIndex + START_SENTINEL.length, endIndex);

  // Strip the inner HTML-comment framing (`<!--` ... `-->`) around the JSON.
  const openIndex = between.indexOf('<!--');

  if (openIndex === -1) return null;

  const closeIndex = between.lastIndexOf('-->');

  if (closeIndex === -1 || closeIndex <= openIndex) return null;

  const payload = between.slice(openIndex + '<!--'.length, closeIndex).trim();

  let parsed: unknown;

  try {
    parsed = JSON.parse(payload);
  } catch {
    return null;
  }

  if (typeof parsed !== 'object' || parsed === null) return null;

  const {auditor: rawAuditor, findings} = parsed as Record<string, unknown>;

  if (!Array.isArray(findings)) return null;

  const auditor =
    typeof rawAuditor === 'string' && rawAuditor.length > 0 ? rawAuditor : '';

  const result: ParsedFinding[] = [];

  for (const entry of findings) {
    const finding = parseFinding(entry, onReject);

    if (finding !== null) result.push(finding);
  }

  return {auditor, findings: result};
};
