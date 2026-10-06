/**
 * Data-layer facts shared by the init subcommand that installs TanStack Query
 * and the scaffolders that emit Query-aware code once it is installed.
 */
import {z} from 'zod';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {templatePath} from './template.js';

export const TANSTACK_QUERY_PACKAGE = '@tanstack/react-query';

/**
 * The exact version the init subcommand pins, and the only place it is
 * written. It must be at least 5.104.0, the first release with
 * `queryClient.query`, which every clientLoader the scaffolds emit awaits. It
 * must also be older than the workspace's `minimumReleaseAge`: the adopter's
 * `pnpm install` is strict about that window and refuses a younger pin.
 */
export const TANSTACK_QUERY_VERSION = '5.104.1';

/** The command that turns TanStack Query on, quoted by refusals that need it. */
export const QUERY_ON_INIT_COMMAND =
  './.gaia/cli/gaia init configure-data-layer --query true';

const dependencyMapSchema = z.record(z.string(), z.unknown()).optional();

const packageJsonSchema = z.looseObject({
  dependencies: dependencyMapSchema,
  devDependencies: dependencyMapSchema,
});

/** Whether parsed `package.json` content declares TanStack Query as a dependency or devDependency. */
export const declaresTanstackQuery = (packageJson: unknown): boolean => {
  const parsed = packageJsonSchema.safeParse(packageJson);

  if (!parsed.success) return false;

  const {dependencies, devDependencies} = parsed.data;

  return (
    Object.hasOwn(dependencies ?? {}, TANSTACK_QUERY_PACKAGE) ||
    Object.hasOwn(devDependencies ?? {}, TANSTACK_QUERY_PACKAGE)
  );
};

/**
 * Whether the frontend package at `packageDir` declares TanStack Query in its
 * dependencies or devDependencies. A missing or unreadable `package.json`
 * reads as not installed.
 */
export const hasTanstackQuery = (packageDir: string): boolean => {
  try {
    return declaresTanstackQuery(
      JSON.parse(readFileSync(path.join(packageDir, 'package.json'), 'utf8'))
    );
  } catch {
    return false;
  }
};

const hasExportedRequest = (source: string, name: string): boolean =>
  new RegExp(
    String.raw`\bexport\s+(?:async\s+)?(?:const|function)\s+${name}\b`,
    'u'
  ).test(source);

/** The getter names `queries.ts` calls, which `requests.ts` must export. */
const queryGetterNames = (names: {
  Plural: string;
  Singular: string;
}): string[] => [`getAll${names.Plural}`, `get${names.Singular}ById`];

/** The getters of `queryGetterNames` that `requestsSource` does not export. */
export const missingQueryGetters = (
  requestsSource: string,
  names: {Plural: string; Singular: string}
): string[] =>
  queryGetterNames(names).filter(
    (name) => !hasExportedRequest(requestsSource, name)
  );

/** Whether `requestsSource` exports every getter `queries.ts` calls. */
export const hasQueryGetters = (
  requestsSource: string,
  names: {Plural: string; Singular: string}
): boolean => missingQueryGetters(requestsSource, names).length === 0;

/** Absolute path of a data-layer template under the scaffold templates. */
export const dataLayerTemplatePath = (fileName: string): string =>
  templatePath(path.join('data-layer', fileName));
