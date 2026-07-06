/**
 * Alphabetical insert into a barrel file (`index.ts` or similar).
 *
 * The four scaffolders all need to register a new module by appending an
 * `export * from './name'` (or named-export) line to a barrel. Sorting
 * barrel entries alphabetically is project convention; doing it once here
 * keeps the four scaffolder tasks free of duplicated string-manipulation
 * code.
 *
 * Idempotent: a second call with the same `exportLine` is a no-op.
 *
 * Heuristic: lines beginning with `export * from` or `export {...} from` are
 * treated as the "sortable region". Comments, blank lines, and other
 * statements at the top or bottom are preserved in place; the new line is
 * inserted into the longest contiguous run of export-from lines that bounds
 * the alphabetically-correct slot.
 */
import {readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';

const EXPORT_FROM_PATTERN = /^\s*export\s+(?:\*|\{[^}]*\})\s+from\s+/u;

const isExportFromLine = (line: string): boolean =>
  EXPORT_FROM_PATTERN.test(line);

type SplitResult = {
  /** Lines without the trailing-newline artifact. */
  lines: string[];
  /** Trailing newline at EOF, if present. */
  trailingNewline: string;
};

const splitPreservingTrailingNewline = (raw: string): SplitResult => {
  if (raw.endsWith('\n')) {
    const body = raw.slice(0, -1);

    return {lines: body.split('\n'), trailingNewline: '\n'};
  }

  return {lines: raw.split('\n'), trailingNewline: ''};
};

type ExportRunBounds = {
  /** Index one-past the last export-from line. */
  end: number;
  /** Index of the first export-from line. */
  start: number;
};

const findExportRun = (lines: string[]): ExportRunBounds | null => {
  let start = -1;
  let end = -1;

  for (const [index, line] of lines.entries()) {
    if (isExportFromLine(line)) {
      if (start === -1) start = index;
      end = index + 1;
    }
  }

  return start === -1 ? null : {end, start};
};

const findInsertIndex = (
  lines: string[],
  bounds: ExportRunBounds,
  newline: string
): number => {
  // `bounds` is derived from this same `lines` array, so every index in
  // [start, end) is guaranteed in-range.
  for (let index = bounds.start; index < bounds.end; index += 1) {
    const candidate = lines[index];

    if (isExportFromLine(candidate) && newline.localeCompare(candidate) < 0) {
      return index;
    }
  }

  return bounds.end;
};

const insertAt = <T>(items: T[], index: number, value: T): T[] => [
  ...items.slice(0, index),
  value,
  ...items.slice(index),
];

const buildOutput = (lines: string[], trailingNewline: string): string =>
  `${lines.join('\n')}${trailingNewline}`;

const insertWhenNoExistingRun = (
  lines: string[],
  exportLine: string
): string[] => {
  // No existing export-from lines. Append after any leading non-blank
  // content; in practice barrels rarely look like this, but the path keeps
  // the helper well-defined.
  if (lines.length === 0) return [exportLine];
  const last = lines.at(-1);

  // If the file ends with a blank line (e.g. content + ""), insert before it
  // so the trailing blank is preserved as the very last visual line.
  if (last === '') return [...lines.slice(0, -1), exportLine, ''];

  return [...lines, exportLine];
};

/**
 * Insert `exportLine` into the barrel at `barrelPath` in alphabetical order.
 *
 * - If `exportLine` already exists verbatim, returns without writing.
 * - Otherwise inserts inside the existing run of `export ... from` lines.
 * - If the file has no such lines, appends (preserving any trailing blank).
 * - Trailing newline at EOF is preserved.
 */
export const insertIntoBarrel = (
  barrelPath: string,
  exportLine: string
): void => {
  const raw = readFileSync(barrelPath, 'utf8');
  const {lines, trailingNewline} = splitPreservingTrailingNewline(raw);

  if (lines.includes(exportLine)) return;

  const bounds = findExportRun(lines);
  const next =
    bounds === null ?
      insertWhenNoExistingRun(lines, exportLine)
    : insertAt(lines, findInsertIndex(lines, bounds, exportLine), exportLine);

  atomicWriteFileSync(barrelPath, buildOutput(next, trailingNewline));
};
