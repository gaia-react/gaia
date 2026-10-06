/**
 * `gaia scaffold service <name>` handler.
 *
 * Replaces the prose `new-service` skill. Emits the per-service folder
 * (`app/services/<layer>/<name>/`) with parsers, types, requests, urls, and a
 * barrel, and when `--mocks` is passed, the matching MSW mock collection
 * under `test/mocks/<name>/` plus an alphabetical insert into
 * `test/mocks/database.ts`. When TanStack Query is installed and the service
 * has a `get` endpoint, it also emits `queries.ts` (key factory plus
 * `queryOptions`).
 *
 * Contract notes:
 *   - `<layer>` is the domain-layer folder under `app/services/`: `--layer`
 *     when passed, else the single directory there other than `api`. The
 *     template ships it as `gaia` and adopters rename it, so it is never
 *     hardcoded.
 *   - Each service is self-contained (its own `urls.ts` and `index.ts`); we do
 *     NOT touch the root `<layer>/urls.ts`.
 *   - `queries.ts` is not exported from the service barrel; routes import it
 *     by path so server-only code never pulls in the Query runtime.
 *   - `--queries-only` writes just `queries.ts` into an existing service
 *     folder, for a service scaffolded before Query was turned on. It refuses
 *     when Query is not installed or `requests.ts` lacks the two getters
 *     `queries.ts` calls.
 *   - Endpoint flag drives which request functions, mock files, and the
 *     handlers-array order. The set is closed: get/post/put/delete only.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  hasTanstackQuery,
  missingQueryGetters,
  QUERY_ON_INIT_COMMAND,
} from './data-layer.js';
import {ensureDir, writeAndRecord} from './fs.js';
import {resolveLayer} from './layer.js';
import {resolveScaffoldTarget} from './resolve-target.js';
import {renderTemplate} from './template.js';
import type {TemplateVars} from './template.js';
import type {ScaffoldResult} from './types.js';

const KEBAB_PATTERN = /^[a-z][a-z\d]*(?:-[a-z\d]+)*$/u;
const LAYER_PATTERN = /^[a-zA-Z][\w-]*$/u;
const NAME_TOKEN_PATTERN =
  /^[a-zA-Z][a-zA-Z\d]*(?::[a-zA-Z][a-zA-Z\d]*(?:\([^)]*\))?)?$/u;
const ALL_ENDPOINTS = ['get', 'post', 'put', 'delete'] as const;

type Endpoint = (typeof ALL_ENDPOINTS)[number];

const ALL_ENDPOINTS_SET: ReadonlySet<string> = new Set(ALL_ENDPOINTS);

type ParsedArgs = {
  endpoints: ReadonlySet<Endpoint>;
  fields: SchemaField[];
  json: boolean;
  layer: string | undefined;
  mocks: boolean;
  name: string;
  queriesOnly: boolean;
};

type SchemaField = {
  /** field name in camelCase (client-side schema) */
  name: string;
  /** Zod expression for client schema (e.g. `z.string()`, `z.literal(['a','b'])`) */
  zodExpression: string;
};

const HELP_TEXT = `Usage: gaia scaffold service <name> --endpoints "get,post,put,delete" --schema "id:string,name:string"

  --endpoints "get,post,put,delete"  required: comma-separated subset of get/post/put/delete
  --schema "id:string,name:string"   required: comma-separated <name>:<type> pairs
                                      type ::= string | number | boolean | datetime |
                                               enum(<a>,<b>,...) | <type>?
  --layer <folder>                   domain-layer folder under app/services/; required only
                                      when more than one folder besides api exists there
  --mocks                            also emit MSW mock collection under test/mocks/<name>/
  --queries-only                     write only queries.ts into an existing service folder
                                      (needs TanStack Query installed; replaces --endpoints
                                      and --schema, which are refused alongside it)
  --json                             emit ScaffoldResult JSON on stdout
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

const userError = (message: string, subcommand: string): number => {
  structuredError({code: 'invalid_arguments', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

// Argument parsing

type FlagMap = {
  endpoints?: string;
  json: boolean;
  layer?: string;
  mocks: boolean;
  positional: string[];
  queriesOnly: boolean;
  schema?: string;
};

const parseFlags = (argv: readonly string[]): FlagMap => {
  const result: FlagMap = {
    json: false,
    mocks: false,
    positional: [],
    queriesOnly: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];

    if (arg !== undefined) {
      if (arg === '--mocks') {
        result.mocks = true;
      } else if (arg === '--json') {
        result.json = true;
      } else if (arg === '--queries-only') {
        result.queriesOnly = true;
      } else if (arg === '--endpoints') {
        result.endpoints = argv[index + 1];
        index += 1;
      } else if (arg === '--schema') {
        result.schema = argv[index + 1];
        index += 1;
      } else if (arg === '--layer') {
        result.layer = argv[index + 1];
        index += 1;
      } else if (!arg.startsWith('--')) {
        result.positional.push(arg);
      }
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

const getZodTypeBuilder = (base: string): (() => string) | undefined =>
  lookupOwn(ZOD_TYPE_BUILDERS, base);

const buildZodExpression = (typeToken: string): null | string => {
  const optional = typeToken.endsWith('?');
  const base = optional ? typeToken.slice(0, -1) : typeToken;
  const enumMatch = ENUM_PATTERN.exec(base);
  let expression: null | string = null;

  if (enumMatch === null) {
    const builder = getZodTypeBuilder(base);

    expression = builder === undefined ? null : builder();
  } else {
    const [, rawVariants] = enumMatch;

    if (rawVariants === undefined) return null;
    const variants = rawVariants.split(',').flatMap((value) => {
      const trimmed = value.trim();

      return trimmed.length > 0 ? [trimmed] : [];
    });

    if (variants.length === 0) return null;
    const quoted = variants.map((value) => `'${value}'`).join(', ');
    expression = `z.literal([${quoted}])`;
  }

  if (expression === null) return null;

  return optional ? `${expression}.nullish()` : expression;
};

const parseSchema = (raw: string): null | SchemaField[] => {
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

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  const flags = parseFlags(argv);
  const name = flags.positional.at(0);

  if (name === undefined) return {error: 'missing required <name>'};

  if (!KEBAB_PATTERN.test(name)) {
    return {
      error: `<name> must be kebab-case (e.g. "projects", "user-settings"); got: ${name}`,
    };
  }

  if (
    flags.layer !== undefined &&
    (!LAYER_PATTERN.test(flags.layer) || flags.layer === 'api')
  ) {
    return {
      error: `--layer must name one domain-layer folder under app/services/ (not api); got: ${flags.layer}`,
    };
  }

  if (flags.queriesOnly) {
    if (flags.endpoints !== undefined || flags.schema !== undefined) {
      return {
        error: '--queries-only does not take --endpoints or --schema',
      };
    }

    if (flags.mocks) return {error: '--queries-only does not take --mocks'};

    return {
      endpoints: new Set(),
      fields: [],
      json: flags.json,
      layer: flags.layer,
      mocks: false,
      name,
      queriesOnly: true,
    };
  }

  if (flags.endpoints === undefined || flags.endpoints.length === 0) {
    return {error: '--endpoints is required'};
  }

  if (flags.schema === undefined || flags.schema.length === 0) {
    return {error: '--schema is required'};
  }

  const endpoints = parseEndpoints(flags.endpoints);

  if (endpoints === null) {
    return {
      error: `--endpoints must be a comma-separated subset of ${ALL_ENDPOINTS.join(',')}`,
    };
  }
  const fields = parseSchema(flags.schema);

  if (fields === null) {
    return {
      error:
        '--schema entries must look like "name:string" (allowed types: string, number, boolean, datetime, enum(a,b,...); append "?" for optional)',
    };
  }

  return {
    endpoints: new Set(endpoints),
    fields,
    json: flags.json,
    layer: flags.layer,
    mocks: flags.mocks,
    name,
    queriesOnly: false,
  };
};

// Name derivation

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

/** kebab → PascalCase. `user-settings` → `UserSettings`. */
export const toPascal = (kebab: string): string =>
  kebab
    .split('-')
    .flatMap((part) =>
      part.length > 0 ? [part.charAt(0).toUpperCase() + part.slice(1)] : []
    )
    .join('');

/** kebab → camelCase. `user-settings` → `userSettings`. */
export const toCamel = (kebab: string): string => {
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

  if (
    kebab.endsWith('xes') ||
    kebab.endsWith('ches') ||
    kebab.endsWith('shes')
  ) {
    return kebab.slice(0, -2);
  }

  if (kebab.endsWith('s') && !kebab.endsWith('ss')) {
    return kebab.slice(0, -1);
  }

  return kebab;
};

export const deriveNames = (name: string): DerivedNames => {
  const singularKebab = singularize(name);

  return {
    name,
    NAME_UPPER: toUpperConst(name),
    Plural: toPascal(name),
    plural: toCamel(name),
    Singular: toPascal(singularKebab),
    singular: toCamel(singularKebab),
  };
};

// Field rendering

/** A camelCase field name as the snake_case key the server sees on the wire. */
export const camelToSnake = (camel: string): string =>
  camel.replaceAll(/[A-Z]/gu, (match) => `_${match.toLowerCase()}`);

const renderClientFields = (fields: SchemaField[]): string[] =>
  fields.map(({name, zodExpression}) => `  ${name}: ${zodExpression},`);

const renderServerFields = (fields: SchemaField[]): string[] =>
  fields.map(({name, zodExpression}) => {
    const snake = camelToSnake(name);
    const key = snake === name ? name : snake;

    return `  ${key}: ${zodExpression},`;
  });

// Mock barrel composition

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

// Database barrel insert

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
      (lines[topInsert]?.startsWith('//') ||
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
  const [, rawInner] = match;

  if (rawInner === undefined) return source;
  const inner = rawInner.trim();
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

  if (source.includes('export default {} as Record<string, never>;')) {
    return source.replace(seedPattern, `export default {${derived.plural}};`);
  }

  const populatedPattern = /export default \{([^}]*)\};/u;
  const match = populatedPattern.exec(source);

  if (match === null) return source;
  const [, rawInner] = match;

  if (rawInner === undefined) return source;
  const inner = rawInner.trim();
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

type ApplyDatabaseEditsArgs = {
  derived: DerivedNames;
  importLine: string;
  resetCall: string;
  source: string;
};

const applyDatabaseEdits = (args: ApplyDatabaseEditsArgs): string => {
  const {derived, importLine, resetCall, source} = args;
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
      'database barrel edit did not apply cleanly: expected import, ' +
        `${resetCall} in the resetTestData Promise.all, and ` +
        `"${derived.plural}" in the default export. ` +
        'Register the collection by hand or fix test/mocks/database.ts.'
    );
  }

  return next;
};

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

  const next = applyDatabaseEdits({
    derived,
    importLine,
    resetCall,
    source: raw,
  });

  if (next === raw) return {written: false};
  atomicWriteFileSync(databasePath, next);

  return {written: true};
};

// Emit

type EmitContext = {
  derived: DerivedNames;
  endpoints: ReadonlySet<Endpoint>;
  fields: SchemaField[];
  layer: string;
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

const baseTemplateVars = (derived: DerivedNames): TemplateVars => ({
  name: derived.name,
  NAME_UPPER: derived.NAME_UPPER,
  Plural: derived.Plural,
  plural: derived.plural,
  Singular: derived.Singular,
  singular: derived.singular,
});

const writeQueries = (
  serviceDir: string,
  baseVars: TemplateVars,
  result: ScaffoldResult
): void => {
  writeAndRecord(
    path.join(serviceDir, 'queries.ts'),
    renderServiceTemplate('service/queries.ts.tmpl', baseVars),
    result
  );
};

const composeRequestsImports = (
  derived: DerivedNames,
  endpoints: ReadonlySet<Endpoint>
): string => {
  const hasSchemaCall =
    endpoints.has('get') || endpoints.has('post') || endpoints.has('put');
  const hasInput = endpoints.has('post') || endpoints.has('put');
  const typeNames = [
    derived.Singular,
    ...(hasInput ? [`${derived.Singular}Input`] : []),
    ...(endpoints.has('get') ? [derived.Plural] : []),
  ];
  const parserNames = [
    ...(endpoints.has('get') ? [`${derived.plural}Schema`] : []),
    ...(hasSchemaCall ? [`${derived.singular}Schema`] : []),
  ];

  return [
    hasSchemaCall ?
      "import {api, envelope} from '../api';"
    : "import {api} from '../api';",
    ...(parserNames.length > 0 ?
      [`import {${parserNames.join(', ')}} from './parsers';`]
    : []),
    ...(hasSchemaCall ?
      [`import type {${typeNames.join(', ')}} from './types';`]
    : []),
    `import {${derived.NAME_UPPER}_URLS} from './urls';`,
  ].join('\n');
};

const emitServiceFiles = (
  context: EmitContext,
  result: ScaffoldResult
): void => {
  const {derived, endpoints, fields, layer, repoRoot} = context;
  const serviceDir = path.join(
    repoRoot,
    'app',
    'services',
    layer,
    derived.name
  );
  ensureDir(serviceDir);

  const baseVars = baseTemplateVars(derived);

  // Server-owned fields stay out of the input a form submits.
  const hasId = fields.some((field) => field.name === 'id');
  const parsersBody = renderServiceTemplate('service/parsers.ts.tmpl', {
    ...baseVars,
    fields: renderClientFields(fields),
    inputSchemaExpression:
      hasId ?
        `${derived.singular}Schema.omit({id: true})`
      : `${derived.singular}Schema`,
  });
  writeAndRecord(path.join(serviceDir, 'parsers.ts'), parsersBody, result);

  const typesBody = renderServiceTemplate('service/types.ts.tmpl', baseVars);
  writeAndRecord(path.join(serviceDir, 'types.ts'), typesBody, result);

  const requestsBody = renderServiceTemplate('service/requests.ts.tmpl', {
    ...baseVars,
    hasDelete: endpoints.has('delete'),
    hasGet: endpoints.has('get'),
    hasPost: endpoints.has('post'),
    hasPut: endpoints.has('put'),
    importLines: composeRequestsImports(derived, endpoints),
  });
  writeAndRecord(path.join(serviceDir, 'requests.ts'), requestsBody, result);

  const urlsBody = renderServiceTemplate('service/urls.ts.tmpl', baseVars);
  writeAndRecord(path.join(serviceDir, 'urls.ts'), urlsBody, result);

  const indexBody = renderServiceTemplate('service/index.ts.tmpl', baseVars);
  writeAndRecord(path.join(serviceDir, 'index.ts'), indexBody, result);

  if (endpoints.has('get') && hasTanstackQuery(repoRoot)) {
    writeQueries(serviceDir, baseVars, result);
  }
};

const emitMockFiles = (context: EmitContext, result: ScaffoldResult): void => {
  const {derived, endpoints, fields, layer, repoRoot} = context;
  const mockDir = path.join(repoRoot, 'test', 'mocks', derived.name);
  ensureDir(mockDir);

  const baseVars: TemplateVars = {...baseTemplateVars(derived), layer};

  const dataBody = renderServiceTemplate('service/mock.data.ts.tmpl', {
    ...baseVars,
    serverFields: renderServerFields(fields),
  });
  writeAndRecord(path.join(mockDir, 'data.ts'), dataBody, result);

  if (endpoints.has('get')) {
    writeAndRecord(
      path.join(mockDir, 'get.ts'),
      renderServiceTemplate('service/mock.get.ts.tmpl', baseVars),
      result
    );
  }

  if (endpoints.has('post')) {
    writeAndRecord(
      path.join(mockDir, 'post.ts'),
      renderServiceTemplate('service/mock.post.ts.tmpl', baseVars),
      result
    );
  }

  if (endpoints.has('put')) {
    writeAndRecord(
      path.join(mockDir, 'put.ts'),
      renderServiceTemplate('service/mock.put.ts.tmpl', baseVars),
      result
    );
  }

  if (endpoints.has('delete')) {
    writeAndRecord(
      path.join(mockDir, 'delete.ts'),
      renderServiceTemplate('service/mock.delete.ts.tmpl', baseVars),
      result
    );
  }

  const barrelBody = renderServiceTemplate('service/mock.index.ts.tmpl', {
    ...baseVars,
    ...composeMockBarrel(endpoints),
  });
  writeAndRecord(path.join(mockDir, 'index.ts'), barrelBody, result);

  // Edit the database barrel; only when --mocks, otherwise no edit.
  const databasePath = path.join(repoRoot, 'test', 'mocks', 'database.ts');

  if (existsSync(databasePath)) {
    const {written} = updateDatabaseBarrel(databasePath, derived);

    if (written) result.edited.push(databasePath);
    else result.skipped.push(databasePath);
  }
};

const emitQueriesOnly = (
  context: EmitContext,
  result: ScaffoldResult
): string | undefined => {
  const {derived, layer, repoRoot} = context;

  if (!hasTanstackQuery(repoRoot)) {
    return `TanStack Query is not installed; run \`${QUERY_ON_INIT_COMMAND}\` first`;
  }

  const serviceDir = path.join(
    repoRoot,
    'app',
    'services',
    layer,
    derived.name
  );
  const requestsPath = path.join(serviceDir, 'requests.ts');

  if (!existsSync(requestsPath)) {
    return `service folder not found or has no requests.ts: app/services/${layer}/${derived.name}/`;
  }

  const requests = readFileSync(requestsPath, 'utf8');
  const missing = missingQueryGetters(requests, derived);

  if (missing.length > 0) {
    return `requests.ts must export ${missing.join(' and ')} for queries.ts to call`;
  }

  writeQueries(serviceDir, baseTemplateVars(derived), result);

  return undefined;
};

const printResult = (result: ScaffoldResult, json: boolean): void => {
  if (json) {
    process.stdout.write(`${JSON.stringify(result)}\n`);

    return;
  }

  for (const created of result.written) process.stdout.write(`+ ${created}\n`);
  for (const edited of result.edited) process.stdout.write(`~ ${edited}\n`);
  for (const skipped of result.skipped) process.stdout.write(`= ${skipped}\n`);
};

// Public entry

export type ServiceRunOptions = {
  /** Directory the command runs in; tests pass a sandbox dir. Defaults to `process.cwd()`. The package root comes from the registry. */
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

  if ('error' in parsed) {
    return userError(parsed.error, 'scaffold service');
  }

  const target = resolveScaffoldTarget(
    options.cwd ?? process.cwd(),
    'scaffold service'
  );

  if (target === undefined) return EXIT_CODES.CONFIG_INVALID;
  const repoRoot = target.packageDir;
  const resolved = resolveLayer(repoRoot, parsed.layer);

  if ('error' in resolved) {
    return userError(resolved.error, 'scaffold service');
  }

  const result: ScaffoldResult = {edited: [], skipped: [], written: []};
  const context: EmitContext = {
    derived: deriveNames(parsed.name),
    endpoints: parsed.endpoints,
    fields: parsed.fields,
    layer: resolved.layer,
    mocks: parsed.mocks,
    repoRoot,
  };

  try {
    if (parsed.queriesOnly) {
      const refusal = emitQueriesOnly(context, result);

      if (refusal !== undefined) return userError(refusal, 'scaffold service');
    } else {
      emitServiceFiles(context, result);
      if (parsed.mocks) emitMockFiles(context, result);
    }
  } catch (error) {
    structuredError({
      code: 'scaffold_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'scaffold service',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  printResult(result, parsed.json);

  return EXIT_CODES.OK;
};
