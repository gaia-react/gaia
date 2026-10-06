/**
 * The pages locale barrel edit and the locale file write shared by the route
 * scaffold's legacy and data paths.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {writeAndRecordWith} from './fs.js';
import type {ScaffoldResult} from './types.js';

type LocaleBarrelInsertResult = 'inserted' | 'missing' | 'present';

// Adjacent `\s*` groups either side of the optional `;?` collapse into an
// ambiguous overlapping-quantifier shape once the semicolon is absent
// (sonarjs/super-linear-regex); folding whitespace-or-semicolon into one
// character class removes the ambiguity.
const CLOSE_BRACE_PATTERN = /^\s*\}[\s;]*$/u;

// Finds where a new `import <name> from '...'` line belongs, alphabetically,
// among the barrel's existing top-of-file import lines.
const findImportInsertIndex = (
  lines: readonly string[],
  importName: string
): number => {
  const importLines: number[] = [];

  for (const [idx, line] of lines.entries()) {
    if (/^import\s/u.test(line)) importLines.push(idx);
  }

  for (const idx of importLines) {
    const existing = lines[idx];

    if (existing !== undefined) {
      const match = /^import\s+(\w+)\s+from/u.exec(existing);

      if (match?.[1] !== undefined && importName.localeCompare(match[1]) < 0) {
        return idx;
      }
    }
  }

  return importLines.length === 0 ? 0 : (importLines.at(-1) ?? 0) + 1;
};

type ExportBlockBounds = {closeIdx: number; openIndex: number};

// Locates the `export default { ... }` block: the line declaring it and its
// closing brace.
const locateExportDefaultBlock = (
  lines: readonly string[]
): ExportBlockBounds | null => {
  const openIndex = lines.findIndex((line) =>
    /export\s+default\s+\{/u.test(line)
  );
  const closeIdx = lines.findIndex(
    (line, idx) => idx > openIndex && CLOSE_BRACE_PATTERN.test(line)
  );

  if (openIndex === -1 || closeIdx === -1) return null;

  return {closeIdx, openIndex};
};

type ExportEntry = {indent: string; key: string; lineIdx: number};

const EXPORT_ENTRY_PATTERN = /^(\s+)(\w+),?\s*$/u;

// Reads the existing `key,` entries inside an `export default { ... }` block
// so a new one can be inserted alphabetically with matching indentation.
const collectExportEntries = (
  lines: readonly string[],
  bounds: ExportBlockBounds
): ExportEntry[] => {
  const entries: ExportEntry[] = [];

  for (let idx = bounds.openIndex + 1; idx < bounds.closeIdx; idx += 1) {
    const line = lines[idx];

    if (line !== undefined) {
      const match = EXPORT_ENTRY_PATTERN.exec(line);

      if (match !== null) {
        const [, indent, key] = match;

        if (indent !== undefined && key !== undefined) {
          entries.push({indent, key, lineIdx: idx});
        }
      }
    }
  }

  return entries;
};

type InsertExportEntryArgs = {
  bounds: ExportBlockBounds;
  entries: readonly ExportEntry[];
  importName: string;
};

// Splices a new `key,` entry into the export block, alphabetically among
// `entries`, mutating `lines` in place.
const insertExportEntry = (
  lines: string[],
  args: InsertExportEntryArgs
): void => {
  const {bounds, entries, importName} = args;
  const indent = entries[0]?.indent ?? '  ';
  const newEntryLine = `${indent}${importName},`;

  if (entries.length === 0) {
    lines.splice(bounds.openIndex + 1, 0, newEntryLine);

    return;
  }

  for (const entry of entries) {
    if (importName.localeCompare(entry.key) < 0) {
      lines.splice(entry.lineIdx, 0, newEntryLine);

      return;
    }
  }

  const lastEntry = entries.at(-1);
  const lastLine =
    lastEntry === undefined ? undefined : lines[lastEntry.lineIdx];

  if (lastEntry === undefined || lastLine === undefined)
    throw new Error(
      'insertExportEntry: the export block has no source line for its last entry; refusing to report a skipped registration as done'
    );

  // Ensure the last entry has a trailing comma so insertion is clean.
  if (!lastLine.endsWith(',')) {
    lines[lastEntry.lineIdx] = `${lastLine},`;
  }

  lines.splice(lastEntry.lineIdx + 1, 0, newEntryLine);
};

type InsertIntoLocaleBarrelArgs = {
  barrelPath: string;
  dryRun: boolean;
  importName: string;
  moduleName: string;
};

/**
 * Insert an `import <name> from './<Folder>';` line and a corresponding
 * entry in the `export default { ... }` block, both alphabetically.
 *
 * The pages locale barrel uses a different shape than the generic
 * `insertIntoBarrel` helper handles (it's import-then-default-export, not
 * `export * from`), so this is local logic.
 */
const insertIntoLocaleBarrel = (
  args: InsertIntoLocaleBarrelArgs
): LocaleBarrelInsertResult => {
  const {barrelPath, dryRun, importName, moduleName} = args;

  if (!existsSync(barrelPath)) return 'missing';
  const original = readFileSync(barrelPath, 'utf8');
  const importLine = `import ${importName} from './${moduleName}';`;

  if (original.includes(importLine)) return 'present';

  const lines = original.split('\n');

  lines.splice(findImportInsertIndex(lines, importName), 0, importLine);

  const bounds = locateExportDefaultBlock(lines);

  if (bounds === null) {
    // Couldn't structurally locate the export block; bail without writing.
    return 'missing';
  }

  insertExportEntry(lines, {
    bounds,
    entries: collectExportEntries(lines, bounds),
    importName,
  });

  const next = lines.join('\n');

  // Diff-safety net: the splice logic above is regex-driven and can
  // mis-target a barrel whose shape drifted from the expected
  // import-then-default-export form. Before writing, prove the result
  // actually contains both the new import line and a matching entry in
  // the default-export block. A non-matching edit fails loudly here
  // instead of silently corrupting the barrel.
  const entryAdded = new RegExp(String.raw`^\s+${importName},?\s*$`, 'mu').test(
    next
  );

  if (!next.includes(importLine) || !entryAdded) {
    throw new Error(
      `locale barrel edit did not apply cleanly to ${barrelPath}: ` +
        `expected import "${importName}" and a matching default-export entry. ` +
        'Add the entries by hand or fix the barrel shape.'
    );
  }

  if (!dryRun) atomicWriteFileSync(barrelPath, next);

  return 'inserted';
};

type WriteLocaleFilesArgs = {
  contents: string;
  dryRun: boolean;
  /** The barrel's import name, which is also the page's i18n key prefix. */
  importName: string;
  /** The locale file's kebab basename under `app/languages/en/pages/`. */
  moduleName: string;
  result: ScaffoldResult;
  root: string;
};

/**
 * Emits the locale file and wires it into the sibling barrel. Returns the
 * failure message when the barrel cannot be wired, `null` on success.
 */
export const writeLocaleFiles = (args: WriteLocaleFilesArgs): null | string => {
  const {contents, dryRun, importName, moduleName, result, root} = args;
  const pagesDir = path.join(root, 'app', 'languages', 'en', 'pages');

  writeAndRecordWith({
    absPath: path.join(pagesDir, `${moduleName}.ts`),
    contents,
    dryRun,
    result,
  });

  const localeBarrel = path.join(pagesDir, 'index.ts');
  const status = insertIntoLocaleBarrel({
    barrelPath: localeBarrel,
    dryRun,
    importName,
    moduleName,
  });

  if (status === 'inserted') {
    result.edited.push(localeBarrel);

    return null;
  }

  if (status === 'present') {
    result.skipped.push(localeBarrel);

    return null;
  }

  // 'missing': the locale file was emitted but the barrel could not be
  // located, so the page's translations are not wired. Fail loudly with
  // an actionable message rather than reporting a misleading success.
  return (
    `locale barrel not found at ${localeBarrel}; the locale file was ` +
    'written but its import was not wired. Run from the repo root, or ' +
    `add "import ${importName} from './${moduleName}';" to the barrel by hand.`
  );
};
