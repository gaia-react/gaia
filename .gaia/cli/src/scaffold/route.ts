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
import {renderTemplate} from './template.js';
import type {TemplateVars} from './template.js';
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
  dryRun: boolean;
  group: null | string;
  i18n: boolean;
  json: boolean;
  loader: boolean;
};

/** Options for `run`, mirroring the other scaffolders so tests can inject a root. */
type RunOptions = {
  /** Repo root used to resolve output paths. Defaults to `process.cwd()`. */
  cwd?: string;
};

const HELP_TEXT = `Usage: gaia scaffold route <name> --group <_public+|_session+> [flags]

  --group     required, _public+ or _session+
  --loader    emit a loader stub
  --action    emit an action stub
  --i18n      emit a locale file and wire the locale barrel
  --dry-run   print what would be written without touching the filesystem
  --json      print ScaffoldResult as JSON
`;

const userError = (message: string, subcommand = 'scaffold route'): number => {
  structuredError({code: 'invalid_input', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const parseFlags = (rest: readonly string[]): null | ParsedFlags => {
  const flags: ParsedFlags = {
    action: false,
    dryRun: false,
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
    } else if (flag === '--dry-run') {
      flags.dryRun = true;
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

  return [
    first,
    ...rest.map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`),
  ].join('');
};

const templateDir = (): string => {
  const here = fileURLToPath(import.meta.url);

  return path.join(path.dirname(here), 'templates', 'route');
};

type LocaleBarrelInsertResult = 'inserted' | 'missing' | 'present';

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
  moduleName: string,
  dryRun: boolean
): LocaleBarrelInsertResult => {
  if (!existsSync(barrelPath)) return 'missing';
  const original = readFileSync(barrelPath, 'utf8');
  const importLine = `import ${importName} from './${moduleName}';`;

  if (original.includes(importLine)) return 'present';

  const lines = original.split('\n');
  const importLines: number[] = [];

  for (const [idx, line] of lines.entries()) {
    if (/^import\s/u.test(line)) importLines.push(idx);
  }

  // Insert the import alphabetically by importName.
  let importInsertIndex =
    importLines.length === 0 ? 0 : (importLines.at(-1) ?? 0) + 1;

  for (const idx of importLines) {
    const existing = lines[idx];

    if (existing === undefined) continue;
    const match = /^import\s+(\w+)\s+from/u.exec(existing);

    if (match?.[1] !== undefined && importName.localeCompare(match[1]) < 0) {
      importInsertIndex = idx;
      break;
    }
  }

  lines.splice(importInsertIndex, 0, importLine);

  // Now insert into the export default { ... } block.
  // Find the line with `export default {` and the closing `};`.
  const openIndex = lines.findIndex((line) =>
    /export\s+default\s+\{/u.test(line)
  );
  const closeIdx = lines.findIndex(
    (line, idx) => idx > openIndex && /^\s*\}\s*;?\s*$/u.test(line)
  );

  if (openIndex === -1 || closeIdx === -1) {
    // Couldn't structurally locate the export block; bail without writing.
    return 'missing';
  }

  // Detect indentation from existing entries.
  const entryPattern = /^(\s+)(\w+),?\s*$/u;
  const existingEntries: {indent: string; key: string; lineIdx: number}[] = [];

  for (let idx = openIndex + 1; idx < closeIdx; idx += 1) {
    const line = lines[idx];

    if (line === undefined) continue;
    const match = entryPattern.exec(line);

    if (match?.[1] !== undefined && match[2] !== undefined) {
      existingEntries.push({indent: match[1], key: match[2], lineIdx: idx});
    }
  }

  const indent = existingEntries[0]?.indent ?? '  ';
  const newEntryLine = `${indent}${importName},`;

  if (existingEntries.length === 0) {
    lines.splice(openIndex + 1, 0, newEntryLine);
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
    // Page folder, component, and the route's import use the `<Pascal>Page`
    // convention (e.g. `IndexPage`); the route component stays `<Pascal>Route`.
    pageName: `${pascal}Page`,
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
  contents: string,
  dryRun: boolean
): void => {
  const {written} = writeFileIfAbsent(absPath, contents, {dryRun});

  if (written) {
    result.written.push(absPath);
  } else {
    result.skipped.push(absPath);
  }
};

const printHumanReadable = (result: ScaffoldResult, dryRun: boolean): void => {
  if (dryRun) process.stdout.write('dry-run: no files written\n');
  const writeLabel = dryRun ? 'would write' : 'written';
  const editLabel = dryRun ? 'would edit' : 'edited';
  const pad = (label: string): string => label.padEnd(11);

  for (const file of result.written) {
    process.stdout.write(`${pad(writeLabel)} ${file}\n`);
  }

  for (const file of result.edited) {
    process.stdout.write(`${pad(editLabel)} ${file}\n`);
  }

  for (const file of result.skipped) {
    process.stdout.write(`${pad('skipped')} ${file}\n`);
  }
};

const printJson = (result: ScaffoldResult): void => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
};

/**
 * Entry point for `gaia scaffold route ...`. Returns the process exit code.
 */
export const run = (
  rest: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = rest;

  if (first === undefined || first === '--help' || first === '-h') {
    process.stdout.write(HELP_TEXT);

    return first === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
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

  // Output paths resolve from the working directory, matching the other
  // scaffolders. The shipped CLI is a single bundle two levels shallower
  // than its source, so deriving the root from the module location (as an
  // earlier version did) overshot the repo root by two directories.
  const root = options.cwd ?? process.cwd();
  const {dryRun} = flags;
  const names = resolveNames(name, flags.group);
  const tmpls = templatePaths();
  const result: ScaffoldResult = {edited: [], skipped: [], written: []};

  try {
    const routeVars = buildRouteVars(names, flags, name);

    const routeAbs = path.join(
      root,
      'app',
      'routes',
      flags.group,
      `${name}.tsx`
    );
    writeFile(result, routeAbs, renderTemplate(tmpls.route, routeVars), dryRun);

    const pageDir = path.join(
      root,
      'app',
      'pages',
      names.groupSegment,
      names.pageName
    );
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
      renderTemplate(tmpls.pageIndex, pageVars),
      dryRun
    );
    writeFile(
      result,
      path.join(pageDir, 'tests', 'index.test.tsx'),
      renderTemplate(tmpls.pageTest, pageVars),
      dryRun
    );
    writeFile(
      result,
      path.join(pageDir, 'tests', 'index.stories.tsx'),
      renderTemplate(tmpls.pageStories, pageVars),
      dryRun
    );

    if (flags.i18n) {
      // Locales are flat files keyed by the kebab route name
      // (app/languages/en/pages/<kebab>.ts), wired into the sibling
      // index.ts barrel by `import <i18nKey> from './<kebab>'`.
      const localeFile = path.join(
        root,
        'app',
        'languages',
        'en',
        'pages',
        `${name}.ts`
      );
      const localeVars: TemplateVars = {
        i18nKey: names.i18nKey,
        pageName: names.pageName,
        routeName: name,
      };
      writeFile(
        result,
        localeFile,
        renderTemplate(tmpls.locale, localeVars),
        dryRun
      );

      const localeBarrel = path.join(
        root,
        'app',
        'languages',
        'en',
        'pages',
        'index.ts'
      );
      const importName = names.i18nKey;
      const status = insertIntoLocaleBarrel(
        localeBarrel,
        importName,
        name,
        dryRun
      );

      if (status === 'inserted') result.edited.push(localeBarrel);
      else if (status === 'present') result.skipped.push(localeBarrel);
      else {
        // 'missing': the locale file was emitted but the barrel could not be
        // located, so the page's translations are not wired. Fail loudly with
        // an actionable message rather than reporting a misleading success.
        return userError(
          `locale barrel not found at ${localeBarrel}; the locale file was ` +
            'written but its import was not wired. Run from the repo root, or ' +
            `add "import ${importName} from './${name}';" to the barrel by hand.`
        );
      }
    }
  } catch (error) {
    return userError(error instanceof Error ? error.message : String(error));
  }

  if (flags.json) printJson(result);
  else printHumanReadable(result, dryRun);

  return EXIT_CODES.OK;
};
