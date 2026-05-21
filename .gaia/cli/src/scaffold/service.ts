/**
 * `gaia scaffold service <name>` handler.
 *
 * Replaces the prose `new-service` skill. Emits the per-service folder
 * (`app/services/gaia/<name>/`) with parsers, types, requests, urls, and a
 * barrel — and, when `--mocks` is passed, the matching MSW mock collection
 * under `test/mocks/<name>/` plus an alphabetical insert into
 * `test/mocks/database.ts`.
 *
 * Contract notes:
 *   - The task spec deliberately makes each service self-contained (its own
 *     `urls.ts` and `index.ts`); we do NOT touch the historical root
 *     `app/services/gaia/urls.ts` or `app/services/gaia/index.server.ts`.
 *   - `requests.server.ts` is preserved as the request-functions filename so
 *     the project's server-only convention (enforced by Vite) keeps holding.
 *   - Endpoint flag drives which request functions, mock files, and the
 *     handlers-array order. The set is closed: get/post/put/delete only.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {fileURLToPath} from 'node:url';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {ensureDir, writeFileIfAbsent} from './fs.js';
import {renderTemplate, type TemplateVars} from './template.js';
import type {ScaffoldResult} from './types.js';

const KEBAB_PATTERN = /^[a-z][a-z\d]*(?:-[a-z\d]+)*$/u;
const NAME_TOKEN_PATTERN = /^[a-zA-Z][a-zA-Z\d]*(?::[a-zA-Z][a-zA-Z\d]*(?:\([^)]*\))?)?$/u;
const ALL_ENDPOINTS = ['get', 'post', 'put', 'delete'] as const;

type Endpoint = (typeof ALL_ENDPOINTS)[number];

const ALL_ENDPOINTS_SET: ReadonlySet<string> = new Set(ALL_ENDPOINTS);

type SchemaField = {
  /** field name in camelCase (client-side schema) */
  name: string;
  /** Zod expression for client schema (e.g. `z.string()`, `z.enum(['a','b'])`) */
  zodExpression: string;
};

type ParsedArgs = {
  endpoints: ReadonlySet<Endpoint>;
  fields: SchemaField[];
  json: boolean;
  mocks: boolean;
  name: string;
};

const HELP_TEXT = `Usage: gaia scaffold service <name> --endpoints "get,post,put,delete" --schema "id:string,name:string"

  --endpoints "get,post,put,delete"  required: comma-separated subset of get/post/put/delete
  --schema "id:string,name:string"   required: comma-separated <name>:<type> pairs
                                      type ::= string | number | boolean | datetime |
                                               enum(<a>,<b>,...) | <type>?
  --mocks                            also emit MSW mock collection under test/mocks/<name>/
  --json                             emit ScaffoldResult JSON on stdout
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

const userError = (message: string, subcommand: string): number => {
  structuredError({code: 'invalid_arguments', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

type FlagMap = {
  endpoints?: string;
  json: boolean;
  mocks: boolean;
  positional: string[];
  schema?: string;
};

const parseFlags = (argv: readonly string[]): FlagMap => {
  const result: FlagMap = {json: false, mocks: false, positional: []};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (arg === '--mocks') {
      result.mocks = true;
    } else if (arg === '--json') {
      result.json = true;
    } else if (arg === '--endpoints') {
      result.endpoints = argv[index + 1];
      index += 1;
    } else if (arg === '--schema') {
      result.schema = argv[index + 1];
      index += 1;
    } else if (arg !== undefined && !arg.startsWith('--')) {
      result.positional.push(arg);
    }
  }

  return result;
};

const parseEndpoints = (raw: string): Endpoint[] | null => {
  const tokens = raw.split(',').flatMap((token) => {
    const normalized = token.trim().toLowerCase();

    return normalized.length > 0 ? [normalized] : [];
  });

  if (tokens.length === 0) return null;

  const endpoints: Endpoint[] = [];

  for (const token of tokens) {
    if (!ALL_ENDPOINTS_SET.has(token)) return null;
    endpoints.push(token as Endpoint);
  }

  return endpoints;
};

const ENUM_PATTERN = /^enum\((.+)\)$/u;
const ZOD_TYPE_BUILDERS: Record<string, () => string> = {
  boolean: () => 'z.boolean()',
  datetime: () => 'z.iso.datetime()',
  number: () => 'z.number()',
  string: () => 'z.string()',
};

const buildZodExpression = (typeToken: string): string | null => {
  const optional = typeToken.endsWith('?');
  const base = optional ? typeToken.slice(0, -1) : typeToken;
  const enumMatch = ENUM_PATTERN.exec(base);
  let expression: string | null = null;

  if (enumMatch !== null) {
    const variants = (enumMatch[1] ?? '').split(',').flatMap((value) => {
      const trimmed = value.trim();

      return trimmed.length > 0 ? [trimmed] : [];
    });

    if (variants.length === 0) return null;
    const quoted = variants.map((value) => `'${value}'`).join(', ');
    expression = `z.enum([${quoted}])`;
  } else {
    const builder = ZOD_TYPE_BUILDERS[base];

    expression = builder === undefined ? null : builder();
  }

  if (expression === null) return null;

  return optional ? `${expression}.nullish()` : expression;
};

const parseSchema = (raw: string): SchemaField[] | null => {
  const tokens = raw
    .split(',')
    // Re-join enum(...) bodies that were split on internal commas. We split the
    // raw string naïvely on commas first, then walk left-to-right re-fusing
    // tokens until parentheses balance.
    .reduce<string[]>((accumulator, piece) => {
      const last = accumulator.at(-1);
      const lastOpen = (last?.match(/\(/gu) ?? []).length;
      const lastClose = (last?.match(/\)/gu) ?? []).length;

      if (last !== undefined && lastOpen > lastClose) {
        accumulator[accumulator.length - 1] = `${last},${piece}`;
      } else {
        accumulator.push(piece);
      }

      return accumulator;
    }, [])
    .flatMap((part) => {
      const trimmed = part.trim();

      return trimmed.length > 0 ? [trimmed] : [];
    });

  if (tokens.length === 0) return null;

  const fields: SchemaField[] = [];

  for (const token of tokens) {
    const colon = token.indexOf(':');

    if (colon === -1) return null;
    const name = token.slice(0, colon).trim();
    const typeToken = token.slice(colon + 1).trim();

    if (name.length === 0 || !NAME_TOKEN_PATTERN.test(name)) return null;
    const zodExpression = buildZodExpression(typeToken);

    if (zodExpression === null) return null;
    fields.push({name, zodExpression});
  }

  return fields;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | string => {
  const flags = parseFlags(argv);
  const name = flags.positional[0];

  if (name === undefined) return 'missing required <name>';
  if (!KEBAB_PATTERN.test(name)) {
    return `<name> must be kebab-case (e.g. "projects", "user-settings"); got: ${name}`;
  }
  if (flags.endpoints === undefined || flags.endpoints.length === 0) {
    return '--endpoints is required';
  }
  if (flags.schema === undefined || flags.schema.length === 0) {
    return '--schema is required';
  }

  const endpoints = parseEndpoints(flags.endpoints);

  if (endpoints === null) {
    return `--endpoints must be a comma-separated subset of ${ALL_ENDPOINTS.join(',')}`;
  }
  const fields = parseSchema(flags.schema);

  if (fields === null) {
    return '--schema entries must look like "name:string" (allowed types: string, number, boolean, datetime, enum(a,b,...); append "?" for optional)';
  }

  return {
    endpoints: new Set(endpoints),
    fields,
    json: flags.json,
    mocks: flags.mocks,
    name,
  };
};

// ---------------------------------------------------------------------------
// Name derivation
// ---------------------------------------------------------------------------

type DerivedNames = {
  /** kebab-case service name (input) */
  name: string;
  /** ALL_CAPS prefix for URL constants (`USER_SETTINGS`) */
  NAME_UPPER: string;
  /** PascalCase plural type/identifier (`UserSettings`) */
  Plural: string;
  /** camelCase plural identifier / collection name (`userSettings`) */
  plural: string;
  /** PascalCase singular type (`UserSetting`) */
  Singular: string;
  /** camelCase singular schema-name root (`userSetting`) */
  singular: string;
};

const toPascal = (kebab: string): string =>
  kebab
    .split('-')
    .flatMap((part) =>
      part.length > 0
        ? [part.charAt(0).toUpperCase() + part.slice(1)]
        : []
    )
    .join('');

const toCamel = (kebab: string): string => {
  const pascal = toPascal(kebab);

  return pascal.charAt(0).toLowerCase() + pascal.slice(1);
};

const toUpperConst = (kebab: string): string =>
  kebab.toUpperCase().replaceAll('-', '_');

const singularize = (kebab: string): string => {
  // Trivial English plural-stripping. Sufficient for the canonical cases
  // (`projects` → `project`, `users` → `user`, `categories` → `category`,
  // `addresses` → `address`). Edge cases (irregular plurals) fall back to the
  // input. Service names are caller-controlled; nothing here is correctness
  // critical.
  if (kebab.endsWith('ies') && kebab.length > 3) {
    return `${kebab.slice(0, -3)}y`;
  }
  if (kebab.endsWith('sses')) {
    return kebab.slice(0, -2);
  }
  if (kebab.endsWith('xes') || kebab.endsWith('ches') || kebab.endsWith('shes')) {
    return kebab.slice(0, -2);
  }
  if (kebab.endsWith('s') && !kebab.endsWith('ss')) {
    return kebab.slice(0, -1);
  }

  return kebab;
};

const deriveNames = (name: string): DerivedNames => {
  const singularKebab = singularize(name);

  return {
    NAME_UPPER: toUpperConst(name),
    Plural: toPascal(name),
    Singular: toPascal(singularKebab),
    name,
    plural: toCamel(name),
    singular: toCamel(singularKebab),
  };
};

// ---------------------------------------------------------------------------
// Field rendering
// ---------------------------------------------------------------------------

const camelToSnake = (camel: string): string =>
  camel.replaceAll(/[A-Z]/gu, (match) => `_${match.toLowerCase()}`);

const renderClientFields = (fields: SchemaField[]): string[] =>
  fields.map(({name, zodExpression}) => `  ${name}: ${zodExpression},`);

const renderServerFields = (fields: SchemaField[]): string[] =>
  fields.map(({name, zodExpression}) => {
    const snake = camelToSnake(name);
    const key = snake === name ? name : snake;

    return `  ${key}: ${zodExpression},`;
  });

// ---------------------------------------------------------------------------
// Mock barrel composition
// ---------------------------------------------------------------------------

const MOCK_IMPORT_LINES: Record<Endpoint, string> = {
  delete: "import del from './delete';",
  get: "import get from './get';",
  post: "import post from './post';",
  put: "import put from './put';",
};

const MOCK_ARRAY_TOKENS: Record<Endpoint, string> = {
  delete: 'del',
  get: '...get',
  post: 'post',
  put: 'put',
};

const composeMockBarrel = (endpoints: ReadonlySet<Endpoint>): TemplateVars => {
  const imports = ALL_ENDPOINTS.flatMap((endpoint) =>
    endpoints.has(endpoint) ? [MOCK_IMPORT_LINES[endpoint]] : []
  ).join('\n');
  const handlersArray = ALL_ENDPOINTS.flatMap((endpoint) =>
    endpoints.has(endpoint) ? [MOCK_ARRAY_TOKENS[endpoint]] : []
  ).join(', ');

  return {handlersArray, imports};
};

// ---------------------------------------------------------------------------
// Database barrel insert
// ---------------------------------------------------------------------------

/**
 * Insert a new collection registration into `test/mocks/database.ts`,
 * preserving alphabetical order of registered collections.
 *
 * The barrel has three load-bearing regions we mutate:
 *   1. Imports of `{collection, resetCollection} from './<name>/data'`.
 *   2. The `Promise.all([...])` argument list inside `resetTestData`.
 *   3. The `default` export object that maps `{<name>}`.
 *
 * Idempotent: if the new entries already exist verbatim, returns
 * `{written: false}`.
 */
const updateDatabaseBarrel = (
  databasePath: string,
  derived: DerivedNames
): {written: boolean} => {
  const raw = readFileSync(databasePath, 'utf8');
  const importLine = `import {${derived.plural}, reset${derived.Plural}} from './${derived.name}/data';`;
  const resetCall = `reset${derived.Plural}()`;

  if (raw.includes(importLine)) return {written: false};

  const next = applyDatabaseEdits(raw, derived, importLine, resetCall);

  if (next === raw) return {written: false};
  atomicWriteFileSync(databasePath, next);

  return {written: true};
};

const insertImportAlphabetically = (
  source: string,
  importLine: string
): string => {
  const lines = source.split('\n');
  const importPattern = /^import\s.*from\s+'\.\/[^']+\/data';$/u;
  let firstImportIndex = -1;
  let lastImportIndex = -1;
  let insertIndex = -1;

  for (const [index, line] of lines.entries()) {
    if (importPattern.test(line)) {
      if (firstImportIndex === -1) firstImportIndex = index;
      lastImportIndex = index;
      if (insertIndex === -1 && importLine.localeCompare(line) < 0) {
        insertIndex = index;
      }
    }
  }

  if (firstImportIndex === -1) {
    // No data imports yet; insert before the first non-import / non-comment
    // line so the new import lives at the top of the file (after any leading
    // comment block).
    let topInsert = 0;

    while (
      topInsert < lines.length &&
      (lines[topInsert]?.startsWith('//') === true ||
        lines[topInsert]?.trim().length === 0)
    ) {
      topInsert += 1;
    }

    return [
      ...lines.slice(0, topInsert),
      importLine,
      '',
      ...lines.slice(topInsert),
    ].join('\n');
  }

  const target = insertIndex === -1 ? lastImportIndex + 1 : insertIndex;

  return [...lines.slice(0, target), importLine, ...lines.slice(target)].join(
    '\n'
  );
};

const insertResetCallAlphabetically = (
  source: string,
  derived: DerivedNames
): string => {
  // Match either `Promise.all([])` (empty) or `Promise.all([a(), b(), ...])`.
  const pattern = /Promise\.all\(\[([^\]]*)\]\)/u;
  const match = pattern.exec(source);

  if (match === null) return source;
  const inner = (match[1] ?? '').trim();
  const newCall = `reset${derived.Plural}()`;

  if (inner.length === 0) {
    return source.replace(pattern, `Promise.all([${newCall}])`);
  }

  const calls = inner.split(',').flatMap((token) => {
    const trimmed = token.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });

  if (calls.includes(newCall)) return source;
  calls.push(newCall);
  calls.sort((leftCall, rightCall) => leftCall.localeCompare(rightCall));
  const replaced = `Promise.all([${calls.join(', ')}])`;

  return source.replace(pattern, replaced);
};

const insertCollectionExportAlphabetically = (
  source: string,
  derived: DerivedNames
): string => {
  // Two forms exist in the wild:
  //   1. Empty seed:    `export default {} as Record<string, never>;`
  //   2. Populated:     `export default {a, b, ...};` (single-line)
  // Both are normalized to the populated single-line form here.
  const seedPattern = /export default \{\} as Record<string, never>;/u;

  if (seedPattern.test(source)) {
    return source.replace(seedPattern, `export default {${derived.plural}};`);
  }

  const populatedPattern = /export default \{([^}]*)\};/u;
  const match = populatedPattern.exec(source);

  if (match === null) return source;
  const inner = (match[1] ?? '').trim();
  const collections = inner.split(',').flatMap((token) => {
    const trimmed = token.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });

  if (collections.includes(derived.plural)) return source;
  collections.push(derived.plural);
  collections.sort((leftCollection, rightCollection) =>
    leftCollection.localeCompare(rightCollection)
  );

  return source.replace(
    populatedPattern,
    `export default {${collections.join(', ')}};`
  );
};

const applyDatabaseEdits = (
  source: string,
  derived: DerivedNames,
  importLine: string,
  resetCall: string
): string => {
  let next = source;
  next = insertImportAlphabetically(next, importLine);

  if (!next.includes(resetCall)) {
    next = insertResetCallAlphabetically(next, derived);
  }
  next = insertCollectionExportAlphabetically(next, derived);

  // Diff-safety net: each of the three inserts is regex-driven and
  // returns `source` unchanged when its target region is missing. A
  // partial application (e.g. the import landed but the `Promise.all`
  // region didn't match) would otherwise be written out as a silently
  // broken barrel. Verify all three regions actually carry the new
  // entries before the caller writes the file; fail loudly otherwise.
  const collectionEntry = new RegExp(
    String.raw`export default \{[^}]*\b${derived.plural}\b`,
    'u'
  ).test(next);

  if (
    !next.includes(importLine) ||
    !next.includes(resetCall) ||
    !collectionEntry
  ) {
    throw new Error(
      `database barrel edit did not apply cleanly: expected import, `
        + `${resetCall} in the resetTestData Promise.all, and `
        + `"${derived.plural}" in the default export. `
        + 'Register the collection by hand or fix test/mocks/database.ts.'
    );
  }

  return next;
};

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

type EmitContext = {
  derived: DerivedNames;
  endpoints: ReadonlySet<Endpoint>;
  fields: SchemaField[];
  mocks: boolean;
  repoRoot: string;
};

const TEMPLATES_DIR = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'templates'
);

const renderServiceTemplate = (
  templateName: string,
  vars: TemplateVars
): string => renderTemplate(path.join(TEMPLATES_DIR, templateName), vars);

const writeRendered = (
  absPath: string,
  contents: string,
  result: ScaffoldResult
): void => {
  const {written} = writeFileIfAbsent(absPath, contents);

  if (written) {
    result.written.push(absPath);
  } else {
    result.skipped.push(absPath);
  }
};

const emitServiceFiles = (context: EmitContext, result: ScaffoldResult): void => {
  const {derived, endpoints, fields, repoRoot} = context;
  const serviceDir = path.join(repoRoot, 'app', 'services', 'gaia', derived.name);
  ensureDir(serviceDir);

  const baseVars: TemplateVars = {
    NAME_UPPER: derived.NAME_UPPER,
    Plural: derived.Plural,
    Singular: derived.Singular,
    name: derived.name,
    plural: derived.plural,
    singular: derived.singular,
  };

  const parsersBody = renderServiceTemplate('service/parsers.ts.tmpl', {
    ...baseVars,
    fields: renderClientFields(fields),
  });
  writeRendered(path.join(serviceDir, 'parsers.ts'), parsersBody, result);

  const typesBody = renderServiceTemplate('service/types.ts.tmpl', baseVars);
  writeRendered(path.join(serviceDir, 'types.ts'), typesBody, result);

  const requestsBody = renderServiceTemplate('service/requests.ts.tmpl', {
    ...baseVars,
    hasDelete: endpoints.has('delete'),
    hasGet: endpoints.has('get'),
    hasPost: endpoints.has('post'),
    hasPut: endpoints.has('put'),
  });
  writeRendered(path.join(serviceDir, 'requests.ts'), requestsBody, result);

  const urlsBody = renderServiceTemplate('service/urls.ts.tmpl', baseVars);
  writeRendered(path.join(serviceDir, 'urls.ts'), urlsBody, result);

  const indexBody = renderServiceTemplate('service/index.ts.tmpl', baseVars);
  writeRendered(path.join(serviceDir, 'index.ts'), indexBody, result);
};

const emitMockFiles = (context: EmitContext, result: ScaffoldResult): void => {
  const {derived, endpoints, fields, repoRoot} = context;
  const mockDir = path.join(repoRoot, 'test', 'mocks', derived.name);
  ensureDir(mockDir);

  const baseVars: TemplateVars = {
    NAME_UPPER: derived.NAME_UPPER,
    Plural: derived.Plural,
    Singular: derived.Singular,
    name: derived.name,
    plural: derived.plural,
    singular: derived.singular,
  };

  const dataBody = renderServiceTemplate('service/mock.data.ts.tmpl', {
    ...baseVars,
    serverFields: renderServerFields(fields),
  });
  writeRendered(path.join(mockDir, 'data.ts'), dataBody, result);

  if (endpoints.has('get')) {
    writeRendered(
      path.join(mockDir, 'get.ts'),
      renderServiceTemplate('service/mock.get.ts.tmpl', baseVars),
      result
    );
  }
  if (endpoints.has('post')) {
    writeRendered(
      path.join(mockDir, 'post.ts'),
      renderServiceTemplate('service/mock.post.ts.tmpl', baseVars),
      result
    );
  }
  if (endpoints.has('put')) {
    writeRendered(
      path.join(mockDir, 'put.ts'),
      renderServiceTemplate('service/mock.put.ts.tmpl', baseVars),
      result
    );
  }
  if (endpoints.has('delete')) {
    writeRendered(
      path.join(mockDir, 'delete.ts'),
      renderServiceTemplate('service/mock.delete.ts.tmpl', baseVars),
      result
    );
  }

  const barrelBody = renderServiceTemplate('service/mock.index.ts.tmpl', {
    ...baseVars,
    ...composeMockBarrel(endpoints),
  });
  writeRendered(path.join(mockDir, 'index.ts'), barrelBody, result);

  // Edit the database barrel — only when --mocks; otherwise no edit.
  const databasePath = path.join(repoRoot, 'test', 'mocks', 'database.ts');

  if (existsSync(databasePath)) {
    const {written} = updateDatabaseBarrel(databasePath, derived);

    if (written) result.edited.push(databasePath);
    else result.skipped.push(databasePath);
  }
};

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

export type ServiceRunOptions = {
  /** Override repo root; tests pass a sandbox dir. Defaults to `process.cwd()`. */
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: ServiceRunOptions = {}
): number => {
  if (argv.length === 0 || argv[0] === '--help' || argv[0] === '-h') {
    printHelp();

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if (typeof parsed === 'string') {
    return userError(parsed, 'scaffold service');
  }

  const result: ScaffoldResult = {edited: [], skipped: [], written: []};
  const context: EmitContext = {
    derived: deriveNames(parsed.name),
    endpoints: parsed.endpoints,
    fields: parsed.fields,
    mocks: parsed.mocks,
    repoRoot: options.cwd ?? process.cwd(),
  };

  try {
    emitServiceFiles(context, result);
    if (parsed.mocks) emitMockFiles(context, result);
  } catch (error) {
    structuredError({
      code: 'scaffold_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'scaffold service',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } else {
    for (const created of result.written) process.stdout.write(`+ ${created}\n`);
    for (const edited of result.edited) process.stdout.write(`~ ${edited}\n`);
    for (const skipped of result.skipped) process.stdout.write(`= ${skipped}\n`);
  }

  return EXIT_CODES.OK;
};
