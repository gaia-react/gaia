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

const SEVERITIES = new Set(['error', 'suggestion', 'warning']);

const parseFinding = (value: unknown): null | ParsedFinding => {
  if (typeof value !== 'object' || value === null) return null;
  const v = value as Record<string, unknown>;

  if (typeof v.finding_class !== 'string' || v.finding_class.length === 0) {
    return null;
  }

  if (typeof v.severity !== 'string' || !SEVERITIES.has(v.severity)) {
    return null;
  }

  if (
    !Array.isArray(v.area_tags) ||
    !v.area_tags.every((tag): tag is string => typeof tag === 'string')
  ) {
    return null;
  }

  return {
    area_tags: v.area_tags,
    finding_class: v.finding_class,
    severity: v.severity as ParsedFinding['severity'],
  };
};

/**
 * Returns the well-formed findings in `body`, `[]` for an explicit empty block,
 * or `null` when no parseable block is present.
 */
export const parseFindingsBlock = (body: string): null | ParsedFinding[] => {
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

  const {findings} = parsed as Record<string, unknown>;

  if (!Array.isArray(findings)) return null;

  const result: ParsedFinding[] = [];

  for (const entry of findings) {
    const finding = parseFinding(entry);

    if (finding !== null) result.push(finding);
  }

  return result;
};
