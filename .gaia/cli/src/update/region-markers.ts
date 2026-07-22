/**
 * Whole-line marker-pair scanner and masker for GAIA's generated-region
 * mechanism: a marker-delimited block inside a shipped file that a shipped
 * command regenerates. Shared by two callers:
 *
 *   - the manifest-build region scan, which reads every shipped file for a
 *     declared marker pair and records it in `.gaia/manifest.json`.
 *   - the merge oracle (`gaia update merge-region`), which masks a region on
 *     each side of a three-way comparison so a regenerated body never reads
 *     as adopter drift.
 *
 * A line matches a marker only when the ENTIRE line equals the marker
 * string, never a substring. This is deliberately NOT
 * `.gaia/cli/src/release/marker-strip.ts`'s semantics: that parser matches a
 * marker as a substring of a line, is destructive (returns text minus the
 * block, never the block's content or offsets), and silently swallows a
 * duplicate start inside an open block. It strips a different marker
 * vocabulary (`gaia:maintainer-only`) for a different purpose (release
 * scrubbing) and stays exactly as it is; this module does not replace it.
 *
 * `.gaia/scripts/write-audit-remits.sh` and
 * `.gaia/scripts/verify-audit-roster.sh` also read whole-line marker pairs,
 * in bash, for the audit-remit region specifically. This module is a fourth
 * implementation, not a replacement for either: both bash parsers stay
 * exactly as they are, and a conformance test binds this parser's semantics
 * to theirs.
 */

export const REGION_PLACEHOLDER = '<<<gaia:region>>>';

export type RegionMalformation =
  'duplicate-end' | 'duplicate-start' | 'inverted' | 'unbalanced';

export type RegionScan =
  | {endLine: number; kind: 'region'; startLine: number}
  | {kind: 'absent'}
  | {kind: 'malformed'; reason: RegionMalformation};

/**
 * Whole-line marker scan. A line matches a marker only when the entire line
 * equals the marker string. Region-bearing means exactly one start and exactly
 * one end, start strictly before end.
 * `startLine` / `endLine` are 1-based line numbers of the marker lines.
 */
export const scanRegion = (
  source: string,
  startMarker: string,
  endMarker: string
): RegionScan => {
  if (startMarker.trim() === '' || endMarker.trim() === '') {
    // An empty (or whitespace-only) marker would otherwise match every blank
    // line in the source. Defence in depth: the caller is expected to reject
    // this as a malformed declaration before it ever reaches the parser.
    return {kind: 'absent'};
  }

  const startLines: number[] = [];
  const endLines: number[] = [];

  source.split('\n').forEach((line, index) => {
    if (line === startMarker) startLines.push(index + 1);
    if (line === endMarker) endLines.push(index + 1);
  });

  if (startLines.length > 1) {
    return {kind: 'malformed', reason: 'duplicate-start'};
  }

  if (endLines.length > 1) {
    return {kind: 'malformed', reason: 'duplicate-end'};
  }

  if (startLines.length === 0 && endLines.length === 0) {
    return {kind: 'absent'};
  }

  if (startLines.length !== endLines.length) {
    return {kind: 'malformed', reason: 'unbalanced'};
  }

  const [startLine] = startLines;
  const [endLine] = endLines;

  // `>=`, not `>`: identical start and end markers put one line in both lists,
  // so `startLine === endLine` describes a zero-length region that masks
  // nothing while duplicating its own marker line. Equal markers are the only
  // way to reach it, since a line cannot equal two different strings.
  if (startLine >= endLine) {
    return {kind: 'malformed', reason: 'inverted'};
  }

  return {endLine, kind: 'region', startLine};
};

/**
 * Replaces every line strictly between the marker pair with the single fixed
 * `REGION_PLACEHOLDER` line. The two marker lines survive. Returns the source
 * unchanged for any non-`region` scan.
 */
export const maskRegion = (
  source: string,
  startMarker: string,
  endMarker: string
): {masked: string; scan: RegionScan} => {
  const scan = scanRegion(source, startMarker, endMarker);

  if (scan.kind !== 'region') {
    return {masked: source, scan};
  }

  const lines = source.split('\n');
  const before = lines.slice(0, scan.startLine);
  const after = lines.slice(scan.endLine - 1);
  const masked = [...before, REGION_PLACEHOLDER, ...after].join('\n');

  return {masked, scan};
};
