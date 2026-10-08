/**
 * `gaia scaffold route <name>` handler.
 *
 * Emits a route file at `app/routes/<group>.<name>.tsx`, a flat
 * `@react-router/fs-routes` file, a page folder under
 * `app/pages/<name>/` (with page.tsx + tests/), and optionally
 * an i18n locale file + alphabetical insert into the locale barrel.
 *
 * Groups are `_public` or `_session`. The group names only the route file
 * prefix; the page tree has no group segment.
 *
 * `--data <server|client|query>` binds the route to a scaffolded service and
 * emits one of the three data-loading wirings, each with a page that reads the
 * data, and a page story that serves it through MSW. Every route module, data
 * or not, renders its page in one line: data hooks, the document title, and
 * meta live in the page, which never imports from `app/routes` (the lint
 * boundary forbids it, type-only imports included), so the loader-data type
 * lives in the page folder's `types.ts`.
 *
 * Templates and the shared scaffold primitives live alongside under
 * `templates/route/` and `template.ts` / `fs.ts` / `barrel.ts`.
 */
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {hasTanstackQuery, QUERY_ON_INIT_COMMAND} from './data-layer.js';
import {writeAndRecordWith} from './fs.js';
import {resolveLayer} from './layer.js';
import {resolveScaffoldTarget} from './resolve-target.js';
import {buildDataPageVars} from './route-data-page.js';
import {buildDataStoryVars} from './route-data-story.js';
import {
  buildDataLocaleVars,
  buildDataRouteVars,
  buildFallbackVars,
  buildLoaderDataVars,
  resolveDataRouteNames,
} from './route-data.js';
import type {
  DataRouteContext,
  DataRouteFlags,
  DataRouteNames,
} from './route-data.js';
import {writeLocaleFiles} from './route-locale.js';
import {deriveRouteCalls, readServiceBinding} from './route-service.js';
import type {DataVariant, RouteShape} from './route-service.js';
import {renderTemplate, templatePath} from './template.js';
import type {TemplateVars} from './template.js';
import type {ScaffoldResult} from './types.js';

const VALID_GROUPS = new Set(['_public', '_session']);
const DATA_VARIANTS: readonly DataVariant[] = ['server', 'client', 'query'];
const ROUTE_SHAPES: readonly RouteShape[] = ['list', 'detail'];

/** Folder names the page layout reserves for its own subfolders. */
const RESERVED_PAGE_NAME_LIST = ['assets', 'hooks', 'state', 'tests', 'utils'];
const RESERVED_PAGE_NAMES = new Set(RESERVED_PAGE_NAME_LIST);

/** kebab-case validation: lowercase letters, digits, hyphens; cannot start or end with hyphen. */
const KEBAB_PATTERN = /^[a-z\d]+(?:-[a-z\d]+)*$/u;

type ParsedFlags = {
  action: boolean;
  data: null | string;
  dryRun: boolean;
  group: null | string;
  i18n: boolean;
  json: boolean;
  layer: null | string;
  loader: boolean;
  service: null | string;
  shape: null | string;
};

/** Options for `run`, mirroring the other scaffolders so tests can inject a root. */
type RunOptions = {
  /** Directory the command runs in; defaults to `process.cwd()`. The package root comes from the registry. */
  cwd?: string;
};

const HELP_TEXT = `Usage: gaia scaffold route <name> --group <_public|_session> [flags]

  --group     required, _public or _session
  --data      bind a service: server (loader), client (clientLoader +
              HydrateFallback), or query (clientLoader + TanStack Query);
              needs --service and --shape
  --service   the service folder under app/services/<layer>/ to bind
  --shape     list (app/routes/<group>.<name>.tsx) or detail
              (app/routes/<group>.<name>_.$id.tsx)
  --layer     the domain-layer folder under app/services/, when there are several
  --loader    emit a title and meta loader (not with --data)
  --action    emit an action stub; with --data, a create (list) or update
              (detail) action validated by the service's input schema
  --i18n      emit a locale file and wire the locale barrel
  --dry-run   print what would be written without touching the filesystem
  --json      print ScaffoldResult as JSON
`;

// The retired `+` spelling must not appear in the error text, so
// that case gets its own message rather than echoing the raw input back.
const invalidGroupMessage = (rawGroup: string): string =>
  rawGroup.endsWith('+') ?
    '--group must be one of: _public, _session (drop the trailing "+"; ' +
    'the route groups are flat file prefixes)'
  : `--group must be one of: _public, _session (got "${rawGroup}")`;

const userError = (message: string, subcommand = 'scaffold route'): number => {
  structuredError({code: 'invalid_input', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const VALUE_FLAGS = {
  '--data': 'data',
  '--group': 'group',
  '--layer': 'layer',
  '--service': 'service',
  '--shape': 'shape',
} as const;

const isValueFlag = (flag: string): flag is keyof typeof VALUE_FLAGS =>
  Object.hasOwn(VALUE_FLAGS, flag);

const parseFlags = (rest: readonly string[]): null | ParsedFlags => {
  const flags: ParsedFlags = {
    action: false,
    data: null,
    dryRun: false,
    group: null,
    i18n: false,
    json: false,
    layer: null,
    loader: false,
    service: null,
    shape: null,
  };

  for (let index = 0; index < rest.length; index += 1) {
    const flag = rest[index] ?? '';

    if (isValueFlag(flag)) {
      const value = rest.at(index + 1);

      if (value === undefined) return null;
      flags[VALUE_FLAGS[flag]] = value;
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

/** Absolute path of a template under `templates/route/`. */
const routeTemplate = (fileName: string): string =>
  templatePath(path.join('route', fileName));

type ResolvedNames = Pick<
  DataRouteNames,
  'i18nKey' | 'pageName' | 'routeFile' | 'routeName'
>;

// The legacy route names are the list route's: page folder, component, and the
// route's import use the `<Pascal>Page` convention (e.g. `IndexPage`), and the
// route component stays `<Pascal>Route`.
const resolveNames = (kebabName: string, group: string): ResolvedNames => {
  const {i18nKey, pageName, routeFile, routeName} = resolveDataRouteNames(
    kebabName,
    group,
    'list'
  );

  return {i18nKey, pageName, routeFile, routeName};
};

type BuildRouteVarsArgs = {
  flags: ParsedFlags;
  name: string;
  names: ResolvedNames;
};

const buildRouteVars = (args: BuildRouteVarsArgs): TemplateVars => {
  const {flags, name, names} = args;
  // Only --i18n writes the `pages` locale keys, so a loader that looks them up
  // without it fails typecheck against the typed i18next resources. The
  // literal loader takes no args, so it needs no `Route` type either.
  const hasLoaderI18n = flags.loader && flags.i18n;

  return {
    hasAction: flags.action,
    hasLoader: flags.loader,
    hasLoaderI18n,
    hasLoaderNoI18n: flags.loader && !flags.i18n,
    i18nKey: names.i18nKey,
    needsRouteType: hasLoaderI18n || flags.action,
    pageName: names.pageName,
    routeFile: names.routeFile,
    routeName: names.routeName,
    routeSlug: name,
  };
};

const padLabel = (label: string): string => label.padEnd(11);

const printHumanReadable = (result: ScaffoldResult, dryRun: boolean): void => {
  if (dryRun) process.stdout.write('dry-run: no files written\n');
  const writeLabel = dryRun ? 'would write' : 'written';
  const editLabel = dryRun ? 'would edit' : 'edited';

  for (const file of result.written) {
    process.stdout.write(`${padLabel(writeLabel)} ${file}\n`);
  }

  for (const file of result.edited) {
    process.stdout.write(`${padLabel(editLabel)} ${file}\n`);
  }

  for (const file of result.skipped) {
    process.stdout.write(`${padLabel('skipped')} ${file}\n`);
  }
};

const printJson = (result: ScaffoldResult): void => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
};

type TemplateWrite = {
  absPath: string;
  template: string;
  vars: TemplateVars;
};

/** Renders each template and writes it, in order, recording the results. */
const writeTemplates = (
  writes: readonly TemplateWrite[],
  dryRun: boolean,
  result: ScaffoldResult
): void => {
  for (const {absPath, template, vars} of writes) {
    writeAndRecordWith({
      absPath,
      contents: renderTemplate(routeTemplate(template), vars),
      dryRun,
      result,
    });
  }
};

type EmitRouteFilesArgs = {
  flags: ParsedFlags;
  name: string;
  names: ResolvedNames;
  result: ScaffoldResult;
  root: string;
};

/** Write the route, page, and optional locale files; a string is the failure message. */
const emitRouteFiles = (args: EmitRouteFilesArgs): null | string => {
  const {flags, name, names, result, root} = args;
  const {dryRun, i18n, loader} = flags;
  const {i18nKey, pageName, routeFile, routeName} = names;
  const pageDir = path.join(root, 'app', 'pages', name);
  const pageVars: TemplateVars = {
    hasI18n: i18n,
    hasImports: i18n || loader,
    hasLoader: loader,
    headingText: i18n ? "{t('title')}" : pageName,
    i18nKey,
    noLoader: !loader,
    pageName,
    routeName,
    routeSlug: name,
  };

  writeTemplates(
    [
      {
        absPath: path.join(root, 'app', 'routes', `${routeFile}.tsx`),
        template: 'route.tsx.tmpl',
        vars: buildRouteVars({flags, name, names}),
      },
      {
        absPath: path.join(pageDir, 'page.tsx'),
        template: 'page.index.tsx.tmpl',
        vars: pageVars,
      },
      {
        absPath: path.join(pageDir, 'tests', 'page.stories.tsx'),
        template: 'page.stories.tsx.tmpl',
        vars: pageVars,
      },
      ...(loader ?
        [
          {
            absPath: path.join(pageDir, 'types.ts'),
            template: 'types.loader.ts.tmpl',
            vars: {},
          },
        ]
      : []),
    ],
    dryRun,
    result
  );

  if (!i18n) return null;

  return writeLocaleFiles({
    contents: renderTemplate(routeTemplate('locale.ts.tmpl'), {
      i18nKey,
      pageName,
      routeName: name,
    }),
    dryRun,
    importName: i18nKey,
    moduleName: name,
    result,
    root,
  });
};

type EmitDataRouteFilesArgs = {
  context: DataRouteContext;
  dryRun: boolean;
  result: ScaffoldResult;
  root: string;
};

/** Write a data route's files; a string is the failure message. */
const emitDataRouteFiles = (args: EmitDataRouteFilesArgs): null | string => {
  const {context, dryRun, result, root} = args;
  const {data, i18n} = context.flags;
  const {names} = context;
  const pageDir = path.join(root, 'app', 'pages', ...names.pagePath.split('/'));

  const fallbackDir = path.join(pageDir, 'hydrate-fallback');

  writeTemplates(
    [
      {
        absPath: path.join(root, 'app', 'routes', `${names.routeFile}.tsx`),
        template: `route.${data}.tsx.tmpl`,
        vars: buildDataRouteVars(context),
      },
      {
        absPath: path.join(pageDir, 'page.tsx'),
        template: 'page.data.tsx.tmpl',
        vars: buildDataPageVars(context),
      },
      ...(data === 'query' ?
        []
      : [
          {
            absPath: path.join(pageDir, 'types.ts'),
            template: 'types.data.ts.tmpl',
            vars: buildLoaderDataVars(context),
          },
        ]),
      ...(data === 'server' ?
        []
      : [
          {
            absPath: path.join(fallbackDir, 'index.tsx'),
            template: 'hydrate-fallback.tsx.tmpl',
            vars: buildFallbackVars(context),
          },
          {
            absPath: path.join(fallbackDir, 'tests', 'index.stories.tsx'),
            template: 'hydrate-fallback.stories.tsx.tmpl',
            vars: buildFallbackVars(context),
          },
        ]),
      {
        absPath: path.join(pageDir, 'tests', 'page.stories.tsx'),
        template: 'page.data.stories.tsx.tmpl',
        vars: buildDataStoryVars(context),
      },
    ],
    dryRun,
    result
  );

  if (!i18n) return null;

  return writeLocaleFiles({
    contents: renderTemplate(
      routeTemplate('locale.data.ts.tmpl'),
      buildDataLocaleVars(context)
    ),
    dryRun,
    importName: names.i18nKey,
    moduleName: names.localeModule,
    result,
    root,
  });
};

type DataSelection = {
  data: DataVariant;
  layer: string | undefined;
  service: string;
  shape: RouteShape;
};

const isOneOf = <Value extends string>(
  allowed: readonly Value[],
  value: string
): value is Value => (allowed as readonly string[]).includes(value);

const LOADER_WITH_DATA_MESSAGE =
  '--loader does not combine with --data: a clientLoader route has no ' +
  'server loader and renders its title and meta from HydrateFallback and ' +
  "the page, and a server data route's page renders them";

/**
 * The flag-only half of the data binding checks, run before anything reads
 * the filesystem. `selection` is null for a route with no `--data`.
 */
const selectData = (
  flags: ParsedFlags
): {error: string} | {selection: DataSelection | null} => {
  const {data, layer, loader, service, shape} = flags;

  if (data === null) {
    return service === null && shape === null && layer === null ?
        {selection: null}
      : {
          error:
            '--service, --shape, and --layer bind a data route; pass --data <server|client|query> with them',
        };
  }

  if (service === null || shape === null) {
    return {
      error: '--data needs --service <name> and --shape <list|detail>',
    };
  }

  if (loader) return {error: LOADER_WITH_DATA_MESSAGE};

  if (!isOneOf(DATA_VARIANTS, data)) {
    return {
      error: `--data must be one of: ${DATA_VARIANTS.join(', ')} (got "${data}")`,
    };
  }

  if (!isOneOf(ROUTE_SHAPES, shape)) {
    return {
      error: `--shape must be one of: ${ROUTE_SHAPES.join(', ')} (got "${shape}")`,
    };
  }

  if (!KEBAB_PATTERN.test(service)) {
    return {
      error: `--service must name a kebab-case service folder: got "${service}"`,
    };
  }

  return {selection: {data, layer: layer ?? undefined, service, shape}};
};

type PrepareDataRouteArgs = {
  flags: ParsedFlags;
  group: string;
  name: string;
  packageDir: string;
  selection: DataSelection;
};

/** The filesystem half of the data binding checks; nothing is written yet. */
const prepareDataRoute = (
  args: PrepareDataRouteArgs
): DataRouteContext | {error: string} => {
  const {flags, group, name, packageDir, selection} = args;

  if (selection.data === 'query' && !hasTanstackQuery(packageDir)) {
    return {
      error: `--data query needs TanStack Query, which this project does not install; turn it on with \`${QUERY_ON_INIT_COMMAND}\` and run pnpm install`,
    };
  }

  const resolved = resolveLayer(packageDir, selection.layer);

  if ('error' in resolved) return resolved;

  const binding = readServiceBinding({
    data: selection.data,
    hasAction: flags.action,
    layer: resolved.layer,
    packageDir,
    service: selection.service,
    shape: selection.shape,
  });

  if ('error' in binding) return binding;

  const dataFlags: DataRouteFlags = {
    action: flags.action,
    data: selection.data,
    i18n: flags.i18n,
    shape: selection.shape,
  };

  return {
    binding,
    calls: deriveRouteCalls(selection.shape, binding.derived),
    flags: dataFlags,
    names: resolveDataRouteNames(name, group, selection.shape),
    slug: name,
  };
};

/** Name and group checks shared by both paths; a string is the failure message. */
const validateNameAndGroup = (
  name: string,
  group: null | string
): null | string => {
  if (!KEBAB_PATTERN.test(name)) {
    return `route name must be kebab-case (lowercase letters, digits, hyphens): got "${name}"`;
  }

  if (RESERVED_PAGE_NAMES.has(name)) {
    return `route name "${name}" is reserved: page folders use it for their own subfolders (reserved: ${RESERVED_PAGE_NAME_LIST.join(', ')})`;
  }

  if (group === null) return '--group is required (one of: _public, _session)';

  if (!VALID_GROUPS.has(group)) return invalidGroupMessage(group);

  return null;
};

type EmitArgs = {
  flags: ParsedFlags;
  group: string;
  name: string;
  root: string;
  selection: DataSelection | null;
};

/** Resolves the data binding when there is one, then writes; a string is the failure message. */
const emit = (args: EmitArgs, result: ScaffoldResult): null | string => {
  const {flags, group, name, root, selection} = args;

  if (selection === null) {
    return emitRouteFiles({
      flags,
      name,
      names: resolveNames(name, group),
      result,
      root,
    });
  }

  const context = prepareDataRoute({
    flags,
    group,
    name,
    packageDir: root,
    selection,
  });

  if ('error' in context) return context.error;

  return emitDataRouteFiles({context, dryRun: flags.dryRun, result, root});
};

/**
 * Entry point for `gaia scaffold route ...`. Returns the process exit code.
 */
export const run = (
  rest: readonly string[],
  options: RunOptions = {}
): number => {
  const first = rest.at(0);

  if (first === undefined || first === '--help' || first === '-h') {
    process.stdout.write(HELP_TEXT);

    return first === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const name = first;
  const flags = parseFlags(rest.slice(1));

  if (flags === null) {
    return userError('invalid or unknown flag (see --help)');
  }

  const invalid = validateNameAndGroup(name, flags.group);

  if (invalid !== null) return userError(invalid);

  const group = flags.group ?? '';
  const dataSelection = selectData(flags);

  if ('error' in dataSelection) return userError(dataSelection.error);

  // Output paths resolve from the frontend package root, which the registry
  // names relative to the working tree root, so the command writes the same
  // files from the repo root and from inside the package. The root is never
  // derived from the module location: the shipped CLI is a single bundle two
  // levels shallower than its source, so that overshoots the repo root.
  const target = resolveScaffoldTarget(
    options.cwd ?? process.cwd(),
    'scaffold route'
  );

  if (target === undefined) return EXIT_CODES.CONFIG_INVALID;
  const result: ScaffoldResult = {edited: [], skipped: [], written: []};

  try {
    const failure = emit(
      {
        flags,
        group,
        name,
        root: target.packageDir,
        selection: dataSelection.selection,
      },
      result
    );

    if (failure !== null) return userError(failure);
  } catch (error) {
    return userError(error instanceof Error ? error.message : String(error));
  }

  if (flags.json) printJson(result);
  else printHumanReadable(result, flags.dryRun);

  return EXIT_CODES.OK;
};
