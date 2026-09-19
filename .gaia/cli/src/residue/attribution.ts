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
 * A near-miss key that fails the gate's own grammar (no `v1` token) is
 * therefore NOT malformed here: the gate does not see it as a key at all, so
 * its unit is keyless on both sides. `parseKey` still refuses such a key with
 * its own reason for a caller holding one from elsewhere.
 *
 * # Inherited behavior this module reproduces deliberately
 *
 * A canonical heading is matched by its TEXT, not by its whole line: the
 * leading `#` run and the one whitespace character after it are stripped from
 * the line under test and from each canonical literal before the comparison,
 * so the heading LEVEL is not load-bearing and a level-three spelling of a
 * canonical literal is canonical. Two things widen with it: the marker run,
 * and the separator, which is any single member of the pattern's character
 * class rather than the literal space the canonical literals carry, so a
 * tab-separated spelling is canonical too. What does not widen is how many
 * separator characters are stripped, so `###  <canonical text>`, two spaces,
 * is still not canonical. That is the gate's behavior and diverging from it
 * here in either direction would break the agreement that is the point.
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
// A comment body may not contain another opener, so a code span quoting a
// bare `<!--` ahead of a real comment cannot start a match that runs on to the
// real comment's closer and deletes the prose between them. A comment wrapped
// whole in a code span takes its backticks with it: the backreference demands
// a closing backtick only when an opening one was consumed. A backtick opens
// the wrapping span only after whitespace or opening punctuation; after any
// other character it is read as closing a neighbouring span, so two spans
// around a bare comment are not merged. Honest limits, both display-only
// since key attribution reads each line separately: prose quoting a bare
// `<!--` and later a bare `-->` reads as one comment and loses the text
// between, and a neighbouring span that itself ends in opening punctuation
// loses its closing backtick.
const HTML_COMMENT_PATTERN =
  /(?:(?<![^\s"'([{])(`))?<!--(?:(?!<!--)[\s\S])*?-->\1/g;
const BLANK_LINE_PATTERN = /^[\t\v\f\r ]*$/;
const INDENTED_LINE_PATTERN = /^[\t ]/;
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
 * The unit's human-readable one-liner, derived from its list item's lines.
 *
 * Carries no newline or carriage return by construction: the store serializer
 * refuses those, and this normalization is what that refusal rests on.
 */
const deriveFailureMode = (textLines: readonly string[]): string =>
  textLines
    .join('\n')
    .replace(TOP_BULLET_PATTERN, '')
    .replaceAll(HTML_COMMENT_PATTERN, ' ')
    .replaceAll(/[\t\n\v\f\r ]+/g, ' ')
    .trim();

type OpenUnit = {
  disposition: ResidueDisposition;
  raw_key: null | string;
  start_line: number;
  text_lines: string[];
  text_state: 'after_blank' | 'closed' | 'collecting';
};

// The text follows the markdown list item, which can end before the unit
// does: a unit runs to the next bullet or heading, so it takes in any prose
// written after the list. Past a blank line, only an indented line continues
// the item.
const collectTextLine = (unit: OpenUnit, line: string): void => {
  if (unit.text_state === 'closed') return;

  if (BLANK_LINE_PATTERN.test(line)) {
    unit.text_state = 'after_blank';

    return;
  }

  if (unit.text_state === 'after_blank' && !INDENTED_LINE_PATTERN.test(line)) {
    unit.text_state = 'closed';

    return;
  }

  unit.text_state = 'collecting';
  unit.text_lines.push(line);
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
    failure_mode: deriveFailureMode(unit.text_lines),
    key: parsed.value,
    raw_key: unit.raw_key,
    unit_start_line: unit.start_line,
  });
};

// The inner key of the leftmost grammar match on one line, or null. The gate
// matches its key regex line by line, so this does too: a `>`-negated field
// applied to a whole body would run past the end of its own comment.
const matchInnerKey = (line: string, keyPattern: RegExp): null | string => {
  const match = new RegExp(
    keyPattern.source,
    keyPattern.flags.replace('g', '')
  ).exec(line);

  return match?.[1] ?? null;
};

// The gate's `heading_text_sed`, over the same language HEADING_PATTERN
// recognizes: a line that reads as a heading is a line this strips a marker
// from. The pattern carries no `g` flag, so `replace` takes the one anchored
// match and neither call site has a `lastIndex` to carry between lines.
const headingText = (line: string): string => line.replace(HEADING_PATTERN, '');

// The literals are written at level two and the remediation text names that
// form, so both sides of each comparison are reduced to heading text rather
// than the canonical spellings being restated once per level.
const canonicalDisposition = (
  trimmedHeading: string,
  predicates: AttributionPredicates
): null | ResidueDisposition => {
  const text = headingText(trimmedHeading);

  if (text === headingText(predicates.canonAccept)) return 'accept';
  if (text === headingText(predicates.canonWaive)) return 'waive';

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
          disposition: inCanonical,
          raw_key: matchInnerKey(line, predicates.keyPattern),
          start_line: lineNumber,
          text_lines: [line],
          text_state: 'collecting',
        };
      } else if (open !== null) {
        collectTextLine(open, line);

        // First match wins: a later key in the same unit is never latched.
        open.raw_key ??= matchInnerKey(line, predicates.keyPattern);
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
