/**
 * The audit-residual dismissal store: a tracked, append-only JSON Lines file
 * at `.gaia/audit-residual-dismissals.jsonl` recording every disposition (a
 * human dismissing, keeping, or the tech-debt filer refusing to promote) a
 * triaged audit residual receives. Append-only because every write is an
 * append, the shape with the smallest merge-conflict surface; a single JSON
 * object would rewrite the whole file on every disposition.
 *
 * `class` is descriptive provenance and never participates in matching.
 * Suppression matches a candidate to a record on `path` and `line` alone
 * (`storeSuppression`, `hasCoordinateRecord`); the resolved-content bind
 * (`cited_line_text`) applies only in `'content-bound'` mode, the
 * interactive run. `'coordinate-only'` mode (the `--count-only` run, which
 * performs no resolution) ignores `cited_line_text` on both sides.
 *
 * The read contract degrades per line, never per file: an unparseable line
 * or a line at an unknown `schema` is reported in `skipped` and excluded
 * from `records`. An unrecognized `disposition` is different, and it is the
 * arm most likely to be implemented backwards: the record is reported in
 * `skipped` **and** kept in `records`, because a reader that does not
 * understand a disposition must not conclude the entry is open, so it still
 * suppresses (the conservative default handled by `storeSuppression`
 * below). An unknown object key on an otherwise-valid record survives on
 * the parsed object untouched, so a future reader that understands it is
 * not robbed by this one.
 */
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  statSync,
} from 'node:fs';
import path from 'node:path';

export const STORE_RELATIVE_PATH = '.gaia/audit-residual-dismissals.jsonl';

export const STORE_SCHEMA_VERSION = 'v1';

export const DEFAULT_KEEP_WINDOW_DAYS = 14;

export type StoreDisposition = 'dismissed' | 'kept' | 'suppressed';

export type StoreRead = {records: StoreRecord[]; skipped: StoreSkip[]};

export type StoreRecord = {
  cited_line_text: string; // resolved line at source_pr's head, '' when unresolvable
  class: string; // descriptive provenance, never participates in matching
  date: string; // ISO-8601 UTC, e.g. 2026-09-13T14:32:00Z
  disposition: StoreDisposition;
  line: number;
  path: string;
  reason: string;
  schema: 'v1';
  source_pr: number;
};

export type StoreSkip = {line_number: number; reason: string};

// 'content-bound' applies the cited-line-text bind (the interactive run).
// 'coordinate-only' matches on path and line alone (the `--count-only` run, which
// resolves nothing); a run using it sets `count_approximate: true` in its emit.
export type SuppressionMode = 'content-bound' | 'coordinate-only';

export type SuppressionVerdict =
  | {record: StoreRecord; suppressed: true; until: null | string}
  | {suppressed: false};

const KNOWN_DISPOSITIONS = new Set<string>(['dismissed', 'kept', 'suppressed']);

const DAY_MS = 24 * 60 * 60 * 1000;

const storePath = (repoRoot: string): string =>
  path.join(repoRoot, ...STORE_RELATIVE_PATH.split('/'));

export const readStore = (repoRoot: string): StoreRead => {
  const filePath = storePath(repoRoot);

  if (!existsSync(filePath)) return {records: [], skipped: []};

  const raw = readFileSync(filePath, 'utf8');
  const records: StoreRecord[] = [];
  const skipped: StoreSkip[] = [];

  raw.split('\n').forEach((line, index) => {
    const lineNumber = index + 1;
    const trimmed = line.trim();

    if (trimmed === '') return;

    let parsed: unknown;

    try {
      parsed = JSON.parse(trimmed);
    } catch {
      skipped.push({line_number: lineNumber, reason: 'unparseable JSON'});

      return;
    }

    if (
      typeof parsed !== 'object' ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      skipped.push({line_number: lineNumber, reason: 'not a JSON object'});

      return;
    }

    const candidate = parsed as Record<string, unknown>;

    if (candidate.schema !== STORE_SCHEMA_VERSION) {
      skipped.push({
        line_number: lineNumber,
        reason: `unknown schema: ${JSON.stringify(candidate.schema)}`,
      });

      return;
    }

    // Cast, not rebuild: the same object is returned, so an unknown key
    // (e.g. `future_field`) survives on the parsed record untouched.
    const record = candidate as unknown as StoreRecord;

    if (!KNOWN_DISPOSITIONS.has(record.disposition)) {
      // Conservative arm: reported, but still added to `records` below so
      // it still suppresses its coordinate.
      skipped.push({
        line_number: lineNumber,
        reason: `unrecognized disposition: ${JSON.stringify(record.disposition)}`,
      });
    }

    records.push(record);
  });

  return {records, skipped};
};

const NEWLINE_CHECKED_FIELDS = [
  'cited_line_text',
  'class',
  'path',
  'reason',
] as const;

const assertNoEmbeddedNewline = (record: StoreRecord): void => {
  for (const field of NEWLINE_CHECKED_FIELDS) {
    if (/[\n\r]/.test(record[field])) {
      throw new Error(
        `audit-residual-dismissals: field "${field}" carries an embedded newline or carriage return`
      );
    }
  }
};

// Explicit alphabetical key order, matching the store's own record
// contract ("keys alphabetized"). JSON.stringify serializes an object's own
// enumerable keys in insertion order, so this order is load-bearing.
const serializeRecord = (record: StoreRecord): string =>
  JSON.stringify({
    cited_line_text: record.cited_line_text,
    class: record.class,
    date: record.date,
    disposition: record.disposition,
    line: record.line,
    path: record.path,
    reason: record.reason,
    schema: record.schema,
    source_pr: record.source_pr,
  });

// `'\n'` when the store exists, is non-empty, and does not already end in a
// newline; `''` otherwise. Reads only the final byte, so the store's size
// does not decide the cost.
const storeNewlinePrefix = (filePath: string): string => {
  if (!existsSync(filePath)) return '';

  let handle: number | undefined;

  try {
    const {size} = statSync(filePath);

    if (size === 0) return '';

    const lastByte = Buffer.alloc(1);

    handle = openSync(filePath, 'r');
    readSync(handle, lastByte, 0, 1, size - 1);

    return lastByte.toString('utf8') === '\n' ? '' : '\n';
  } catch {
    // Unreadable for any reason: the append below is what reports the real
    // failure, so do not turn a read problem into a spurious newline.
    return '';
  } finally {
    if (handle !== undefined) closeSync(handle);
  }
};

export const appendRecords = (
  repoRoot: string,
  records: readonly StoreRecord[]
): void => {
  // Validate every record before touching the file: a refusal on any one
  // record must leave the store byte-for-byte unchanged, never a partial
  // write.
  records.forEach(assertNoEmbeddedNewline);

  if (records.length === 0) return;

  const filePath = storePath(repoRoot);
  const body = records.map((record) => `${serializeRecord(record)}\n`).join('');

  mkdirSync(path.dirname(filePath), {recursive: true});
  // A store whose last line lost its newline, which a merge conflict resolved
  // without `insert_final_newline` produces, would otherwise take this append
  // onto the end of that line. `readStore` then drops BOTH records as one
  // unparseable line: the prior dismissal stops suppressing and the record
  // just written was never readable, while this call still exits 0. Nothing
  // here creates that state, but this is where it becomes destructive.
  appendFileSync(filePath, `${storeNewlinePrefix(filePath)}${body}`, {
    flag: 'a',
  });
};

export const readKeepWindowDays = (env: NodeJS.ProcessEnv): number => {
  const raw = env.GAIA_RESIDUE_KEEP_DAYS;

  if (raw === undefined) return DEFAULT_KEEP_WINDOW_DAYS;

  const parsed = Number.parseInt(raw, 10);

  if (!Number.isInteger(parsed) || parsed <= 0) {
    return DEFAULT_KEEP_WINDOW_DAYS;
  }

  return parsed;
};

/* eslint-disable max-params -- frozen five-argument signature (Dismissal store, Phase 1b exports); Phase 2 binds against this shape */
export const storeSuppression = (
  records: readonly StoreRecord[],
  candidate: {cited_line_text: string; line: number; path: string},
  now: Date,
  keepWindowDays: number,
  mode: SuppressionMode
): SuppressionVerdict => {
  const matching = records.filter(
    (record) =>
      record.path === candidate.path &&
      record.line === candidate.line &&
      (mode === 'coordinate-only' ||
        record.cited_line_text === candidate.cited_line_text)
  );

  // Last one in file order wins: append-only means later records are later
  // decisions.
  const winner = matching.at(-1);

  if (winner === undefined) return {suppressed: false};

  // Widened to `string`: a record's disposition is read off disk, so an
  // unrecognized value is a real runtime possibility the StoreDisposition
  // union does not admit at the type level.
  const disposition: string = winner.disposition;

  if (disposition === 'dismissed' || disposition === 'suppressed') {
    return {record: winner, suppressed: true, until: null};
  }

  if (disposition === 'kept') {
    const decidedAt = Date.parse(winner.date);
    const ageMs = now.getTime() - decidedAt;

    if (ageMs < keepWindowDays * DAY_MS) {
      return {
        record: winner,
        suppressed: true,
        until: new Date(decidedAt + keepWindowDays * DAY_MS).toISOString(),
      };
    }

    return {suppressed: false};
  }

  // Unrecognized disposition: the conservative arm. A reader that does not
  // understand a disposition must not conclude the entry is open.
  return {record: winner, suppressed: true, until: null};
};
/* eslint-enable max-params */

// Whether any record shares the candidate's coordinate at all, ignoring
// content. The tally uses this to decide which candidates need a
// resolution before the content bind can be evaluated.
export const hasCoordinateRecord = (
  records: readonly StoreRecord[],
  candidate: {line: number; path: string}
): boolean =>
  records.some(
    (record) => record.path === candidate.path && record.line === candidate.line
  );
