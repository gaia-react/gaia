/**
 * Reads the service a data route binds to (`gaia scaffold route --data ...
 * --service <name>`): its schema fields from `parsers.ts`, the request
 * functions the route calls, and the wire casing its stories mock.
 *
 * The reads are line-based on purpose. `gaia scaffold service` writes
 * `parsers.ts` one field per line, and parsing it with the TypeScript compiler
 * would bundle TypeScript into the shipped CLI. A service whose files no longer
 * match that shape is refused with the shape spelled out, never guessed at.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {deriveNames} from './service.js';

export type DataVariant = 'client' | 'query' | 'server';

export type FieldKind = 'boolean' | 'datetime' | 'enum' | 'number' | 'string';

export type RouteCalls = {
  /** The loader-data key and the page's destructured name. */
  dataKey: string;
  /** The request that reads the route's data. */
  getter: string;
  /** The request the route's action submits to. */
  mutation: string;
  /** The query options factory a `query` route reads through. */
  query: string;
};

export type RouteShape = 'detail' | 'list';

export type ServiceBinding = {
  derived: ReturnType<typeof deriveNames>;
  /** The `id` field, which the list links and the detail route param use. */
  idField: ServiceField;
  /** Every schema field except `id`, in schema order: the form's inputs. */
  inputFields: ServiceField[];
  layer: string;
  name: string;
  /** False when the layer's `api.ts` turns the snake_case conversion off. */
  snakeCaseWire: boolean;
};

export type ServiceField = {
  /** The literal values of an enum field, in schema order; empty otherwise. */
  enumValues: string[];
  kind: FieldKind;
  name: string;
  /** `.nullish()`, `.optional()`, or `.nullable()`: the form may leave it empty. */
  nullish: boolean;
};

/** The names a route of `shape` calls on its bound service. */
export const deriveRouteCalls = (
  shape: RouteShape,
  derived: ServiceBinding['derived']
): RouteCalls => {
  const {Plural, plural, Singular, singular} = derived;

  return shape === 'list' ?
      {
        dataKey: plural,
        getter: `getAll${Plural}`,
        mutation: `create${Singular}`,
        query: `${plural}Query`,
      }
    : {
        dataKey: singular,
        getter: `get${Singular}ById`,
        mutation: `update${Singular}`,
        query: `${singular}Query`,
      };
};

type ReadServiceBindingArgs = {
  data: DataVariant;
  hasAction: boolean;
  layer: string;
  packageDir: string;
  service: string;
  shape: RouteShape;
};

const FIELD_LINE_PATTERN = /^ {2}(\w+): (.+),$/u;
const ENUM_VALUES_PATTERN = /^z\.(?:enum|literal)\(\[(.*)\]\)/u;
const NULLISH_PATTERN = /\.(?:nullish|nullable|optional)\(\)/u;

// Expression prefixes the scaffold knows how to render an input and a sample
// value for. `gaia scaffold service` emits the first form of each; the rest are
// the spellings an adopter most often edits a field to.
const KIND_PREFIXES: readonly (readonly [string, FieldKind])[] = [
  ['z.boolean(', 'boolean'],
  ['z.coerce.boolean(', 'boolean'],
  ['z.iso.datetime(', 'datetime'],
  ['z.number(', 'number'],
  ['z.coerce.number(', 'number'],
  ['z.literal([', 'enum'],
  ['z.enum([', 'enum'],
  ['z.string(', 'string'],
  ['z.email(', 'string'],
  ['z.url(', 'string'],
  ['z.uuid(', 'string'],
];

const parseEnumValues = (expression: string): string[] => {
  const match = ENUM_VALUES_PATTERN.exec(expression);

  if (match?.[1] === undefined) return [];

  return match[1]
    .split(',')
    .map((value) => value.trim().replaceAll(/^['"]|['"]$/gu, ''))
    .filter((value) => value.length > 0);
};

const parseField = (name: string, expression: string): null | ServiceField => {
  const kind = KIND_PREFIXES.find(([prefix]) =>
    expression.startsWith(prefix)
  )?.[1];

  if (kind === undefined) return null;

  const enumValues = kind === 'enum' ? parseEnumValues(expression) : [];

  if (kind === 'enum' && enumValues.length === 0) return null;

  return {enumValues, kind, name, nullish: NULLISH_PATTERN.test(expression)};
};

const relativeServicePath = (args: ReadServiceBindingArgs, file: string) =>
  `app/services/${args.layer}/${args.service}/${file}`;

const parsersShapeMessage = (file: string, singular: string): string =>
  `cannot read the schema fields in ${file}. The route scaffold expects the ` +
  `shape \`gaia scaffold service\` writes: an \`export const ${singular}Schema = ` +
  'z.object({` line, one `  <name>: <zod expression>,` line per field, then ' +
  `\`});\`, with an \`id\` field and an \`export const ${singular}InputSchema\`. ` +
  `Field expressions must start with one of: ${KIND_PREFIXES.map(
    ([prefix]) => prefix
  ).join(' ')}`;

type FieldBlockResult = {error: string} | {fields: ServiceField[]};

const readFieldBlock = (
  source: string,
  singular: string,
  file: string
): FieldBlockResult => {
  const unreadable = {error: parsersShapeMessage(file, singular)};
  const lines = source.split('\n');
  const open = lines.indexOf(`export const ${singular}Schema = z.object({`);

  if (open === -1) return unreadable;

  const fields: ServiceField[] = [];

  for (const line of lines.slice(open + 1)) {
    if (line === '});') return fields.length > 0 ? {fields} : unreadable;

    const match = FIELD_LINE_PATTERN.exec(line);
    const field =
      match?.[1] === undefined || match[2] === undefined ?
        null
      : parseField(match[1], match[2]);

    if (field === null) {
      return {
        error: `${parsersShapeMessage(file, singular)}. Unreadable line: "${line}"`,
      };
    }

    fields.push(field);
  }

  return unreadable;
};

const exportsName = (source: string, name: string): boolean =>
  new RegExp(
    String.raw`\bexport\s+(?:async\s+)?(?:const|function)\s+${name}\b`,
    'u'
  ).test(source);

const readOptional = (filePath: string): null | string =>
  existsSync(filePath) ? readFileSync(filePath, 'utf8') : null;

/** The request functions the route module and its page call for this shape. */
const requiredRequests = (
  args: ReadServiceBindingArgs,
  derived: ReturnType<typeof deriveNames>
): string[] => {
  const {getter, mutation} = deriveRouteCalls(args.shape, derived);

  return args.hasAction ? [getter, mutation] : [getter];
};

type RequestsCheckArgs = {
  args: ReadServiceBindingArgs;
  derived: ReturnType<typeof deriveNames>;
  serviceDir: string;
};

// Refuses before anything is written when the generated route would call a
// function the service does not export, which would otherwise surface only as
// a typecheck failure in the scaffolded files.
const checkServiceExports = ({
  args,
  derived,
  serviceDir,
}: RequestsCheckArgs): null | string => {
  const requestsFile = relativeServicePath(args, 'requests.ts');
  const requests = readOptional(path.join(serviceDir, 'requests.ts'));
  const missing = requiredRequests(args, derived).filter(
    (name) => requests === null || !exportsName(requests, name)
  );

  if (missing.length > 0) {
    return `${requestsFile} does not export ${missing.join(', ')}; scaffold the service with the matching --endpoints first`;
  }

  if (args.data !== 'query') return null;

  const queries = readOptional(path.join(serviceDir, 'queries.ts'));

  if (queries === null) {
    return (
      `--data query needs ${relativeServicePath(args, 'queries.ts')}; run ` +
      `\`./.gaia/cli/gaia scaffold service ${args.service} --queries-only --layer ${args.layer}\` first`
    );
  }

  return null;
};

/** Whether the layer's request factory keeps its default snake_case wire conversion. */
const readSnakeCaseWire = (packageDir: string, layer: string): boolean => {
  const api = readOptional(
    path.join(packageDir, 'app', 'services', layer, 'api.ts')
  );

  return api === null || !/useSnakeCase:\s*false/u.test(api);
};

/**
 * Reads and checks the bound service. Returns the binding, or the refusal
 * message naming the file and what it lacks.
 */
export const readServiceBinding = (
  args: ReadServiceBindingArgs
): ServiceBinding | {error: string} => {
  const serviceDir = path.join(
    args.packageDir,
    'app',
    'services',
    args.layer,
    args.service
  );

  if (!existsSync(serviceDir)) {
    return {
      error: `service folder not found: app/services/${args.layer}/${args.service}/ (scaffold it with \`./.gaia/cli/gaia scaffold service ${args.service}\` first)`,
    };
  }

  const derived = deriveNames(args.service);
  const parsersFile = relativeServicePath(args, 'parsers.ts');
  const parsers = readOptional(path.join(serviceDir, 'parsers.ts'));

  if (parsers === null) {
    return {error: parsersShapeMessage(parsersFile, derived.singular)};
  }

  const block = readFieldBlock(parsers, derived.singular, parsersFile);

  if ('error' in block) return block;

  const idField = block.fields.find((field) => field.name === 'id');
  const inputFields = block.fields.filter((field) => field.name !== 'id');

  if (
    idField === undefined ||
    inputFields.length === 0 ||
    !exportsName(parsers, `${derived.singular}InputSchema`)
  ) {
    return {error: parsersShapeMessage(parsersFile, derived.singular)};
  }

  const exportsError = checkServiceExports({args, derived, serviceDir});

  if (exportsError !== null) return {error: exportsError};

  return {
    derived,
    idField,
    inputFields,
    layer: args.layer,
    name: args.service,
    snakeCaseWire: readSnakeCaseWire(args.packageDir, args.layer),
  };
};
