/**
 * Pure attribution core for audit residue recorded in a pull-request body.
 *
 * Re-implements, in TypeScript, the rule the merge gate
 * (`.claude/hooks/audit-residual-shape-check.sh`) already implements in bash:
 * which headings are canonical, where one entry unit ends and the next
 * begins, and which dedup keys count. The gate is the reference and this side
 * agrees with it or it is wrong; a conformance comparison drives both over one
 * fixture corpus to hold the two together.
 *
 * No I/O lives here: the caller supplies a body string and gets back the
 * attribution. The recognizer literals and the key grammar are injectable
 * values rather than inlined constants, so a conformance test can mutate one
 * predicate and watch the comparison red without editing this module.
 *
 * # The three populations, and why they partition the units
 *
 * Every entry unit beneath a canonical heading lands in exactly one of
 * `entries`, `malformed`, or `keyless`, so a consumer can rebuild one tuple
 * per unit and compare it against the gate's own per-unit emit.
 *
 * - `keyless` is a unit carrying no match of the gate's grammar anywhere
 *   within it. The gate calls this keyless and denies the merge over it.
 * - `malformed` is a unit whose key MATCHES the gate's grammar but whose
 *   fields fail validation (an absolute or traversal path, a line outside the
 *   bounds). The gate counts the unit as keyed, so this side does too; the
 *   entry is withheld and the reason is reported rather than the key dropped.
 * - `entries` is everything else.
 *
 * A near-miss key that fails the gate's own grammar (no `v1` token, a spaced
 * path) is therefore NOT malformed here: the gate does not see it as a key at
 * all, so its unit is keyless on both sides. `parseKey` still refuses such a
 * key with its own reason for a caller holding one from elsewhere.
 *
 * # Inherited behavior this module reproduces deliberately
 *
 * A canonical heading is matched by whole-line equality after a trailing
 * whitespace trim, so the heading LEVEL is load-bearing: a level-three
 * spelling of a canonical literal is not canonical. That is the gate's
 * behavior and repairing it here would break the agreement that is the point.
 */
import {KEY_PATTERN, parseKey} from './key.js';
import type {ResidueKey} from './key.js';

export type {ResidueKey} from './key.js';

export const CANON_ACCEPT = '## Accepted residuals (recorded, not fixed)';

export const CANON_WAIVE =
  '## Out-of-scope machinery findings (recorded, not filed)';

export type AttributedEntry = {
  disposition: ResidueDisposition;
  failure_mode: string;
  key: ResidueKey;
  raw_key: string;
  unit_start_line: number;
};

export type AttributionPredicates = {
  canonAccept: string;
  canonWaive: string;
  keyPattern: RegExp;
};

export type AttributionResult = {
  entries: AttributedEntry[];
  keyless: KeylessUnit[];
  keyless_count: number;
  malformed: MalformedKey[];
};

export type KeylessUnit = {
  disposition: ResidueDisposition;
  unit_start_line: number;
};

export type MalformedKey = {
  disposition: ResidueDisposition;
  raw_key: string;
  reason: string;
  unit_start_line: number;
};

export type ResidueDisposition = 'accept' | 'waive';

export const DEFAULT_PREDICATES: AttributionPredicates = {
  canonAccept: CANON_ACCEPT,
  canonWaive: CANON_WAIVE,
  keyPattern: KEY_PATTERN,
};

// The gate's `heading_re` and `top_bullet_re`, with POSIX `[[:space:]]` spelled
// out member by member. A line never carries its own newline, but the class is
// reproduced whole so each regex reads against the gate's source. `\d` and the
// gate's `[0-9]` denote the same set here: JavaScript's `\d` is ASCII digits
// under every flag.
const HEADING_PATTERN = /^#{1,6}[\t\n\v\f\r ]/;
const TOP_BULLET_PATTERN = /^([-*+]|\d{1,9}[.)])[\t\n\v\f\r ]/;
const HTML_COMMENT_PATTERN = /<!--[\s\S]*?-->/g;
const TRAILING_SPACE_CHARACTERS = new Set(['\t', '\n', '\v', '\f', '\r', ' ']);

// A backward walk rather than a `[…]+$` regex, which backtracks quadratically
// on a long run, and rather than `trimEnd`, which strips the whole Unicode
// whitespace set and would trim a heading the gate's `[[:space:]]` leaves
// alone.
const trimTrailingSpace = (line: string): string => {
  let end = line.length;

  while (end > 0 && TRAILING_SPACE_CHARACTERS.has(line[end - 1] ?? '')) {
    end -= 1;
  }

  return line.slice(0, end);
};

/**
 * The unit's human-readable one-liner, derived from its opening bullet line.
 *
 * Carries no newline or carriage return by construction: the store serializer
 * refuses those, and this normalization is what that refusal rests on.
 */
const deriveFailureMode = (bulletLine: string): string =>
  bulletLine
    .replace(TOP_BULLET_PATTERN, '')
    .replaceAll(HTML_COMMENT_PATTERN, ' ')
    .replaceAll(/[\t\n\v\f\r ]+/g, ' ')
    .trim();

type OpenUnit = {
  bullet_line: string;
  disposition: ResidueDisposition;
  raw_key: null | string;
  start_line: number;
};

const closeUnit = (unit: OpenUnit, result: AttributionResult): void => {
  if (unit.raw_key === null) {
    result.keyless.push({
      disposition: unit.disposition,
      unit_start_line: unit.start_line,
    });

    return;
  }

  const parsed = parseKey(unit.raw_key, 'gate');

  if (!parsed.ok) {
    result.malformed.push({
      disposition: unit.disposition,
      raw_key: unit.raw_key,
      reason: parsed.reason,
      unit_start_line: unit.start_line,
    });

    return;
  }

  result.entries.push({
    disposition: unit.disposition,
    failure_mode: deriveFailureMode(unit.bullet_line),
    key: parsed.value,
    raw_key: unit.raw_key,
    unit_start_line: unit.start_line,
  });
};

// The inner key of the leftmost grammar match on one line, or null. The gate
// matches its key regex line by line, so this does too: a `[^ ]+` field must
// never be allowed to span a line break.
const matchInnerKey = (line: string, keyPattern: RegExp): null | string => {
  const match = new RegExp(
    keyPattern.source,
    keyPattern.flags.replace('g', '')
  ).exec(line);

  return match?.[1] ?? null;
};

const canonicalDisposition = (
  trimmedHeading: string,
  predicates: AttributionPredicates
): null | ResidueDisposition => {
  if (trimmedHeading === predicates.canonAccept) return 'accept';
  if (trimmedHeading === predicates.canonWaive) return 'waive';

  return null;
};

/**
 * Attributes one pull-request body against the supplied recognizer
 * predicates. `attributeBody` is this with the defaults.
 */
export const attributeBodyWith = (
  body: string,
  predicates: AttributionPredicates
): AttributionResult => {
  const result: AttributionResult = {
    entries: [],
    keyless: [],
    keyless_count: 0,
    malformed: [],
  };

  let inCanonical: null | ResidueDisposition = null;
  let open: null | OpenUnit = null;

  const close = (): void => {
    if (open !== null) closeUnit(open, result);
    open = null;
  };

  const lines = body.split('\n');

  for (const [index, line] of lines.entries()) {
    const lineNumber = index + 1;

    if (HEADING_PATTERN.test(line)) {
      // A heading of any level closes the open unit and drops out of the
      // canonical section; only a whole-line match re-enters one.
      close();
      inCanonical = canonicalDisposition(trimTrailingSpace(line), predicates);
    } else if (inCanonical !== null) {
      if (TOP_BULLET_PATTERN.test(line)) {
        close();
        open = {
          bullet_line: line,
          disposition: inCanonical,
          raw_key: matchInnerKey(line, predicates.keyPattern),
          start_line: lineNumber,
        };
      } else if (open !== null && open.raw_key === null) {
        // First match wins: a later key in the same unit is never latched.
        open.raw_key = matchInnerKey(line, predicates.keyPattern);
      }
    }
  }

  close();

  result.keyless_count = result.keyless.length;

  return result;
};

/** Attributes one pull-request body against the default recognizer. */
export const attributeBody = (body: string): AttributionResult =>
  attributeBodyWith(body, DEFAULT_PREDICATES);
