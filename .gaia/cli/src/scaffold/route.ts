/**
 * `gaia scaffold route <name>` handler.
 *
 * Emits a route file under `app/routes/<group>/`, a page folder under
 * `app/pages/<Group>/<PageName>/` (with index.tsx + tests/), and optionally
 * an i18n locale file + alphabetical insert into the locale barrel.
 *
 * Group folders are React Router 7 flat-route groups: `_public+` or
 * `_session+`. Group segment in the page tree maps to `Public` / `Session`.
 *
 * Templates and the shared scaffold primitives live alongside under
 * `templates/route/` and `template.ts` / `fs.ts` / `barrel.ts`.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {writeFileIfAbsent} from './fs.js';
import {renderTemplate, type TemplateVars} from './template.js';
import type {ScaffoldResult} from './types.js';

const VALID_GROUPS = new Set(['_public+', '_session+']);

const GROUP_TO_SEGMENT: Readonly<Record<string, string>> = {
  '_public+': 'Public',
  '_session+': 'Session',
};

/** kebab-case validation: lowercase letters, digits, hyphens; cannot start or end with hyphen. */
const KEBAB_PATTERN = /^[a-z\d]+(?:-[a-z\d]+)*$/u;

type ParsedFlags = {
  action: boolean;
  group: string | null;
  i18n: boolean;
  json: boolean;
  loader: boolean;
};

const HELP_TEXT = `Usage: gaia scaffold route <name> --group <_public+|_session+> [flags]

  --group     required, _public+ or _session+
  --loader    emit a loader stub
  --action    emit an action stub
  --i18n      emit a locale file and wire the locale barrel
  --json      print ScaffoldResult as JSON
`;

const userError = (message: string, subcommand = 'scaffold route'): number => {
  structuredError({code: 'invalid_input', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const parseFlags = (rest: readonly string[]): ParsedFlags | null => {
  const flags: ParsedFlags = {
    action: false,
    group: null,
    i18n: false,
    json: false,
    loader: false,
  };

  for (let index = 0; index < rest.length; index += 1) {
    const flag = rest[index];

    if (flag === '--group') {
      const value = rest[index + 1];

      if (value === undefined) return null;
      flags.group = value;
      index += 1;
    } else if (flag === '--loader') {
      flags.loader = true;
    } else if (flag === '--action') {
      flags.action = true;
    } else if (flag === '--i18n') {
      flags.i18n = true;
    } else if (flag === '--json') {
      flags.json = true;
    } else {
      return null;
    }
  }

  return flags;
};

/** kebab → PascalCase. `user-settings` → `UserSettings`. */
const toPascalCase = (kebab: string): string =>
  kebab
    .split('-')
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join('');

/** kebab → camelCase. `user-settings` → `userSettings`. */
const toCamelCase = (kebab: string): string => {
  const parts = kebab.split('-');
  const [first, ...rest] = parts;

  return [first, ...rest.map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)].join('');
};

const repoRoot = (): string => {
  // This file lives at .gaia/cli/src/scaffold/route.ts; repo root is four levels up.
  const here = fileURLToPath(import.meta.url);

  return path.resolve(path.dirname(here), '..', '..', '..', '..');
};

const templateDir = (): string => {
  const here = fileURLToPath(import.meta.url);

  return path.join(path.dirname(here), 'templates', 'route');
};

type LocaleBarrelInsertResult = 'inserted' | 'present' | 'missing';

/**
 * Insert an `import <name> from './<Folder>';` line and a corresponding
 * entry in the `export default { ... }` block, both alphabetically.
 *
 * The pages locale barrel uses a different shape than the generic
 * `insertIntoBarrel` helper handles (it's import-then-default-export, not
 * `export * from`), so this is local logic.
 */
const insertIntoLocaleBarrel = (
  barrelPath: string,
  importName: string,
  folderName: string
): LocaleBarrelInsertResult => {
  if (!existsSync(barrelPath)) return 'missing';
  const original = readFileSync(barrelPath, 'utf8');
  const importLine = `import ${importName} from './${folderName}';`;

  if (original.includes(importLine)) return 'present';

  const lines = original.split('\n');
  const importLines: number[] = [];

  for (const [idx, line] of lines.entries()) {
    if (/^import\s/u.test(line)) importLines.push(idx);
  }

  // Insert the import alphabetically by importName.
  let importInsertIdx = importLines.length === 0 ? 0 : (importLines.at(-1) ?? 0) + 1;

  for (const idx of importLines) {
    const existing = lines[idx];

    if (existing === undefined) continue;
    const match = existing.match(/^import\s+(\w+)\s+from/u);

    if (match && match[1] !== undefined && importName.localeCompare(match[1]) < 0) {
      importInsertIdx = idx;
      break;
    }
  }

  lines.splice(importInsertIdx, 0, importLine);

  // Now insert into the export default { ... } block.
  // Find the line with `export default {` and the closing `};`.
  const openIdx = lines.findIndex((line) => /export\s+default\s+\{/u.test(line));
  const closeIdx = lines.findIndex(
    (line, idx) => idx > openIdx && /^\s*\}\s*;?\s*$/u.test(line)
  );

  if (openIdx === -1 || closeIdx === -1) {
    // Couldn't structurally locate the export block; bail without writing.
    return 'missing';
  }

  // Detect indentation from existing entries.
  const entryPattern = /^(\s+)(\w+),?\s*$/u;
  const existingEntries: Array<{indent: string; key: string; lineIdx: number}> = [];

  for (let idx = openIdx + 1; idx < closeIdx; idx += 1) {
    const line = lines[idx];

    if (line === undefined) continue;
    const match = line.match(entryPattern);

    if (match && match[1] !== undefined && match[2] !== undefined) {
      existingEntries.push({indent: match[1], key: match[2], lineIdx: idx});
    }
  }

  const indent = existingEntries[0]?.indent ?? '  ';
  const newEntryLine = `${indent}${importName},`;

  if (existingEntries.length === 0) {
    lines.splice(openIdx + 1, 0, newEntryLine);
  } else {
    let inserted = false;

    for (const entry of existingEntries) {
      if (importName.localeCompare(entry.key) < 0) {
        lines.splice(entry.lineIdx, 0, newEntryLine);
        inserted = true;
        break;
      }
    }

    if (!inserted) {
      const lastEntry = existingEntries.at(-1);

      if (lastEntry !== undefined) {
        // Ensure the last entry has a trailing comma so insertion is clean.
        const lastLine = lines[lastEntry.lineIdx];

        if (lastLine !== undefined && !lastLine.endsWith(',')) {
          lines[lastEntry.lineIdx] = `${lastLine},`;
        }

        lines.splice(lastEntry.lineIdx + 1, 0, newEntryLine);
      }
    }
  }

  const next = lines.join('\n');

  // Diff-safety net: the splice logic above is regex-driven and can
  // mis-target a barrel whose shape drifted from the expected
  // import-then-default-export form. Before writing, prove the result
  // actually contains both the new import line and a matching entry in
  // the default-export block. A non-matching edit fails loudly here
  // instead of silently corrupting the barrel.
  const entryAdded = new RegExp(
    String.raw`^\s+${importName},?\s*$`,
    'mu'
  ).test(next);

  if (!next.includes(importLine) || !entryAdded) {
    throw new Error(
      `locale barrel edit did not apply cleanly to ${barrelPath}: `
        + `expected import "${importName}" and a matching default-export entry. `
        + 'Add the entries by hand or fix the barrel shape.'
    );
  }

  atomicWriteFileSync(barrelPath, next);

  return 'inserted';
};

type TemplatePaths = {
  locale: string;
  pageIndex: string;
  pageStories: string;
  pageTest: string;
  route: string;
};

const templatePaths = (): TemplatePaths => {
  const dir = templateDir();

  return {
    locale: path.join(dir, 'locale.ts.tmpl'),
    pageIndex: path.join(dir, 'page.index.tsx.tmpl'),
    pageStories: path.join(dir, 'page.stories.tsx.tmpl'),
    pageTest: path.join(dir, 'page.test.tsx.tmpl'),
    route: path.join(dir, 'route.tsx.tmpl'),
  };
};

type ResolvedNames = {
  groupSegment: string;
  i18nKey: string;
  pageName: string;
  routeName: string;
};

const resolveNames = (kebabName: string, group: string): ResolvedNames => {
  const pascal = toPascalCase(kebabName);
  const segment = GROUP_TO_SEGMENT[group] ?? '';

  return {
    groupSegment: segment,
    i18nKey: toCamelCase(kebabName),
    pageName: pascal,
    routeName: pascal,
  };
};

const buildRouteVars = (
  names: ResolvedNames,
  flags: ParsedFlags,
  kebabName: string
): TemplateVars => ({
  groupSegment: names.groupSegment,
  hasAction: flags.action,
  hasLoader: flags.loader,
  i18nKey: names.i18nKey,
  needsRouteType: flags.loader || flags.action,
  noLoader: !flags.loader,
  pageName: names.pageName,
  routeFile: kebabName,
  routeName: names.routeName,
});

const writeFile = (
  result: ScaffoldResult,
  absPath: string,
  contents: string
): void => {
  const {written} = writeFileIfAbsent(absPath, contents);

  if (written) {
    result.written.push(absPath);
  } else {
    result.skipped.push(absPath);
  }
};

const printHumanReadable = (result: ScaffoldResult): void => {
  for (const file of result.written) process.stdout.write(`written  ${file}\n`);
  for (const file of result.edited) process.stdout.write(`edited   ${file}\n`);
  for (const file of result.skipped) process.stdout.write(`skipped  ${file}\n`);
};

const printJson = (result: ScaffoldResult): void => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
};

/**
 * Entry point for `gaia scaffold route ...`. Returns the process exit code.
 */
export const run = (rest: readonly string[]): number => {
  const [first] = rest;

  if (first === undefined || first === '--help' || first === '-h') {
    process.stdout.write(HELP_TEXT);

    return first === undefined
      ? EXIT_CODES.UNKNOWN_SUBCOMMAND
      : EXIT_CODES.OK;
  }

  const name = first;
  const flags = parseFlags(rest.slice(1));

  if (flags === null) {
    return userError('invalid or unknown flag (see --help)');
  }

  if (!KEBAB_PATTERN.test(name)) {
    return userError(
      `route name must be kebab-case (lowercase letters, digits, hyphens): got "${name}"`
    );
  }

  if (flags.group === null) {
    return userError('--group is required (one of: _public+, _session+)');
  }

  if (!VALID_GROUPS.has(flags.group)) {
    return userError(
      `--group must be one of: _public+, _session+ (got "${flags.group}")`
    );
  }

  const root = repoRoot();
  const names = resolveNames(name, flags.group);
  const tmpls = templatePaths();
  const result: ScaffoldResult = {edited: [], skipped: [], written: []};

  try {
    const routeVars = buildRouteVars(names, flags, name);

    const routeAbs = path.join(root, 'app', 'routes', flags.group, `${name}.tsx`);
    writeFile(result, routeAbs, renderTemplate(tmpls.route, routeVars));

    const pageDir = path.join(root, 'app', 'pages', names.groupSegment, names.pageName);
    const pageVars: TemplateVars = {
      groupSegment: names.groupSegment,
      hasI18n: flags.i18n,
      i18nKey: names.i18nKey,
      noI18n: !flags.i18n,
      pageName: names.pageName,
    };

    writeFile(
      result,
      path.join(pageDir, 'index.tsx'),
      renderTemplate(tmpls.pageIndex, pageVars)
    );
    writeFile(
      result,
      path.join(pageDir, 'tests', 'index.test.tsx'),
      renderTemplate(tmpls.pageTest, pageVars)
    );
    writeFile(
      result,
      path.join(pageDir, 'tests', 'index.stories.tsx'),
      renderTemplate(tmpls.pageStories, pageVars)
    );

    if (flags.i18n) {
      const localeFile = path.join(
        root,
        'app',
        'languages',
        'en',
        'pages',
        names.pageName,
        'index.ts'
      );
      const localeVars: TemplateVars = {
        i18nKey: names.i18nKey,
        pageName: names.pageName,
        routeName: name,
      };
      writeFile(result, localeFile, renderTemplate(tmpls.locale, localeVars));

      const localeBarrel = path.join(
        root,
        'app',
        'languages',
        'en',
        'pages',
        'index.ts'
      );
      const importName = names.i18nKey;
      const status = insertIntoLocaleBarrel(localeBarrel, importName, names.pageName);

      if (status === 'inserted') result.edited.push(localeBarrel);
      else if (status === 'present') result.skipped.push(localeBarrel);
    }
  } catch (error) {
    return userError(error instanceof Error ? error.message : String(error));
  }

  if (flags.json) printJson(result);
  else printHumanReadable(result);

  return EXIT_CODES.OK;
};
