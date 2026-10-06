/**
 * Template variables for the data routes `gaia scaffold route --data ...`
 * writes: the route module, the page and its loader-data type, the client
 * variants' HydrateFallback, and the locale file. The page's variables live
 * in `route-data-page.ts` and the page story's in `route-data-story.ts`.
 *
 * Everything that varies with the bound service's fields (form inputs, the
 * detail list, the story's record) is built as text in these modules, so each
 * template stays one flat frame per file. The template engine has no else-branches and no nested iteration,
 * and growing it is the thing its own header rules out.
 */
import type {
  DataVariant,
  RouteCalls,
  RouteShape,
  ServiceBinding,
  ServiceField,
} from './route-service.js';
import {toCamel, toPascal} from './service.js';
import type {TemplateVars} from './template.js';

/** camelCase or kebab-case → sentence case. `displayName` → `Display name`. */
export const humanize = (identifier: string): string => {
  const words = identifier
    .replaceAll(/[A-Z]/gu, (letter) => ` ${letter}`)
    .replaceAll('-', ' ')
    .toLowerCase()
    .trim();

  return `${words.charAt(0).toUpperCase()}${words.slice(1)}`;
};

export type DataRouteFlags = {
  action: boolean;
  data: DataVariant;
  i18n: boolean;
  shape: RouteShape;
};

export type DataRouteNames = {
  description: string;
  fallbackName: string;
  i18nKey: string;
  localeModule: string;
  pageName: string;
  /** Folder under `app/pages/`, `items` or `items/id`. */
  pagePath: string;
  routeFile: string;
  routeName: string;
  storyTitle: string;
  title: string;
};

/**
 * Names for a data route. The detail route file is `<name>_.$id`: the trailing
 * underscore keeps it a sibling of the list route rather than nested under it,
 * and it is dropped when deriving the page folder, so the pair shares
 * `pages/<name>/`.
 */
export const resolveDataRouteNames = (
  name: string,
  group: string,
  shape: RouteShape
): DataRouteNames => {
  const pascal = toPascal(name);
  const camel = toCamel(name);

  if (shape === 'list') {
    return {
      description: `Description of the ${name} page`,
      fallbackName: `${pascal}HydrateFallback`,
      i18nKey: camel,
      localeModule: name,
      pageName: `${pascal}Page`,
      pagePath: name,
      routeFile: `${group}.${name}`,
      routeName: pascal,
      storyTitle: pascal,
      title: humanize(name),
    };
  }

  return {
    description: `Description of the ${name} detail page`,
    fallbackName: `${pascal}DetailHydrateFallback`,
    i18nKey: `${camel}Detail`,
    localeModule: `${name}-detail`,
    pageName: `${pascal}DetailPage`,
    pagePath: `${name}/id`,
    routeFile: `${group}.${name}_.$id`,
    routeName: `${pascal}Detail`,
    storyTitle: `${pascal}/Id`,
    title: `${humanize(name)} detail`,
  };
};

export type DataRouteContext = {
  binding: ServiceBinding;
  /** The service names this route calls, derived once from the shape. */
  calls: RouteCalls;
  flags: DataRouteFlags;
  names: DataRouteNames;
  /** The kebab route name: the list URL and every action's redirect target. */
  slug: string;
};

// The frontend's Prettier print width. Emitting within it leaves the adopter's
// `pnpm lint` (which runs Prettier through ESLint) nothing to reflow.
export const MAX_LINE_LENGTH = 80;

/** Joins source lines, each terminated by a newline. */
export const block = (...lines: readonly string[]): string =>
  lines.map((line) => `${line}\n`).join('');

export const indent = (depth: number): string => ' '.repeat(depth);

/** `head{a, b}tail` on one line when it fits, else one destructured name per line. */
export const destructure = (
  head: string,
  names: readonly string[],
  tail: string
): string => {
  const oneLine = `${head}{${names.join(', ')}}${tail}`;

  if (oneLine.length <= MAX_LINE_LENGTH) return oneLine;

  const members = names.map((name) => `  ${name},`);

  return [`${head}{`, ...members, `}${tail}`].join('\n');
};

/** `oneLine` when it fits, else the `wrapped` lines. */
export const fitOnLine = (
  oneLine: string,
  wrapped: readonly string[]
): string =>
  oneLine.length <= MAX_LINE_LENGTH ? block(oneLine) : block(...wrapped);

/** The page's `<meta name="description">` element, wrapped when it does not fit. */
export const metaElement = (depth: number, content: string): string => {
  const pad = indent(depth);

  return fitOnLine(`${pad}<meta content=${content} name="description" />`, [
    `${pad}<meta`,
    `${pad}  content=${content}`,
    `${pad}  name="description"`,
    `${pad}/>`,
  ]);
};

/** A single-quoted TypeScript string literal. */
export const toLiteral = (value: string): string => {
  const escaped = value.replaceAll("'", String.raw`\'`);

  return `'${escaped}'`;
};

export const sortNames = (names: readonly string[]): string[] =>
  names.toSorted((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));

export const serviceImportPath = (context: DataRouteContext): string =>
  `~/services/${context.binding.layer}/${context.binding.name}`;

export const isList = (context: DataRouteContext): boolean =>
  context.flags.shape === 'list';

export const fieldLabel = (field: ServiceField): string => humanize(field.name);

/** The field a list row links with: the first required text-like field, else the id. */
export const linkLabelField = (context: DataRouteContext): ServiceField =>
  context.binding.inputFields.find(
    (field) =>
      field.kind !== 'boolean' && field.kind !== 'number' && !field.nullish
  ) ?? context.binding.idField;

/**
 * The loader and action export names for a variant. The `Route` type each
 * takes is the export name capitalized plus `Args`.
 */
export const dataExportNames = (
  data: DataVariant
): {action: string; loader: string} => ({
  action: data === 'query' ? 'clientAction' : 'action',
  loader: data === 'server' ? 'loader' : 'clientLoader',
});

const routeArgsType = (exportName: string): string =>
  `Route.${exportName.charAt(0).toUpperCase()}${exportName.slice(1)}Args`;

const dataSignatures = (context: DataRouteContext): TemplateVars => {
  const {data} = context.flags;
  const params = isList(context) ? ['request'] : ['params', 'request'];
  const {action: actionName, loader: loaderName} = dataExportNames(data);
  const queryLoaderSignature =
    isList(context) ?
      'export const clientLoader = async () => {'
    : destructure(
        'export const clientLoader = async (',
        ['params'],
        ': Route.ClientLoaderArgs) => {'
      );

  return {
    actionSignature: destructure(
      `export const ${actionName} = async (`,
      params,
      `: ${routeArgsType(actionName)}) => {`
    ),
    loaderSignature:
      data === 'query' ? queryLoaderSignature : (
        destructure(
          `export const ${loaderName} = async (`,
          params,
          `: ${routeArgsType(loaderName)}): Promise<LoaderData> => ({`
        )
      ),
  };
};

const routeImportLines = (context: DataRouteContext): string => {
  const {derived} = context.binding;
  const {getter, mutation, query} = context.calls;
  const {action, data} = context.flags;
  const service = serviceImportPath(context);
  const pages = `~/pages/${context.names.pagePath}`;
  const inputSchemaImport = `import {${derived.singular}InputSchema} from '${service}';`;
  const requestNames = action ? [getter, mutation] : [getter];
  const queryNames = [query, ...(action ? [`${derived.singular}Keys`] : [])];
  const dataImports =
    data === 'query' ?
      [
        "import {getQueryClient} from '~/query-client';",
        ...(action ? [inputSchemaImport] : []),
        `import {${sortNames(queryNames).join(', ')}} from '${service}/queries';`,
        ...(action ? [`import {${mutation}} from '${service}/requests';`] : []),
      ]
    : [
        `import type {LoaderData} from '${pages}/types';`,
        ...(action ? [inputSchemaImport] : []),
        `import {${sortNames(requestNames).join(', ')}} from '${service}/requests';`,
      ];
  const needsRouteType = data !== 'query' || action || !isList(context);

  return [
    ...(action ?
      [
        "import {redirect} from 'react-router';",
        "import {parseWithZod} from '@conform-to/zod/v4';",
      ]
    : []),
    ...(data === 'server' ?
      []
    : [
        `import ${context.names.fallbackName} from '${pages}/hydrate-fallback';`,
      ]),
    `import ${context.names.pageName} from '${pages}/page';`,
    ...dataImports,
    ...(needsRouteType ?
      [`import type {Route} from './+types/${context.names.routeFile}';`]
    : []),
  ].join('\n');
};

/** Variables for `route.<server|client|query>.tsx.tmpl`. */
export const buildDataRouteVars = (context: DataRouteContext): TemplateVars => {
  const {derived} = context.binding;
  const {dataKey, getter, mutation, query} = context.calls;
  const list = isList(context);

  return {
    ...dataSignatures(context),
    dataKey,
    fallbackName: context.names.fallbackName,
    getterCall: `${getter}(${list ? '' : 'params.id, '}request.signal)`,
    hasAction: context.flags.action,
    importLines: routeImportLines(context),
    inputSchema: `${derived.singular}InputSchema`,
    keysName: `${derived.singular}Keys`,
    mutationCall: `${mutation}(${list ? '' : 'params.id, '}submission.value)`,
    pageName: context.names.pageName,
    queryCall: `${query}(${list ? '' : 'params.id'})`,
    routeName: context.names.routeName,
    routeSlug: context.slug,
  };
};

/** Variables for `hydrate-fallback.tsx.tmpl` and its story. */
export const buildFallbackVars = (context: DataRouteContext): TemplateVars => ({
  hasI18n: context.flags.i18n,
  i18nKey: context.names.i18nKey,
  metaLine: metaElement(4, `"${context.names.description}"`),
  noI18n: !context.flags.i18n,
  storyTitle: context.names.storyTitle,
  title: context.names.title,
});

/** Variables for `types.data.ts.tmpl`. */
export const buildLoaderDataVars = (
  context: DataRouteContext
): TemplateVars => {
  const {derived} = context.binding;

  return {
    dataKey: context.calls.dataKey,
    serviceImport: serviceImportPath(context),
    typeName: isList(context) ? derived.Plural : derived.Singular,
  };
};

/** `key: value,` lines sorted by key, as Prettier and the key-sort rule leave them. */
export const objectLiteralLines = (
  entries: readonly (readonly [string, string])[],
  depth: number
): string =>
  block(
    ...entries
      .toSorted(([a], [b]) => a.localeCompare(b))
      .map(([key, value]) => `${indent(depth)}${key}: ${value},`)
  );

/** Variables for `locale.data.ts.tmpl`. */
export const buildDataLocaleVars = (
  context: DataRouteContext
): TemplateVars => ({
  description: context.names.description,
  fieldLabelLines: objectLiteralLines(
    context.binding.inputFields.map((field) => [
      field.name,
      toLiteral(fieldLabel(field)),
    ]),
    4
  ),
  title: context.names.title,
});
