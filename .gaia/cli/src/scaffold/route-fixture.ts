/**
 * Test support for the route scaffold suites: the route-module and lint
 * boundary checks they share, and a hand-written service folder in the shape
 * `gaia scaffold service` emits, so the data-route suite does not depend on the
 * service scaffold to build its input.
 */
import {expect} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run} from './route.js';

export type Sandbox = {cleanup: () => void; root: string};

/**
 * A fresh temp dir holding a frontend registry, so the scaffolded `app/` tree
 * lands in isolation and the real shipped templates render unchanged.
 */
export const setupSandbox = (prefix: string): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), prefix));

  writeFrontendRegistry(root);

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

const captureStream = (stream: NodeJS.WriteStream): {restore: () => string} => {
  const chunks: string[] = [];
  const original = stream.write.bind(stream);

  stream.write = (chunk: unknown): boolean => {
    chunks.push(String(chunk));

    return true;
  };

  return {
    restore: (): string => {
      stream.write = original;

      return chunks.join('');
    },
  };
};

export const captureStdout = (): {restore: () => string} =>
  captureStream(process.stdout);

export const captureStderr = (): {restore: () => string} =>
  captureStream(process.stderr);

type RunResult = {exit: number; stderr: string; stdout: string};

/** Runs the scaffold with stdout and stderr captured. */
export const scaffold = (root: string, args: readonly string[]): RunResult => {
  const stdout = captureStdout();
  const stderr = captureStderr();
  let exit: number;

  try {
    exit = run(args, {cwd: root});
  } catch (error) {
    stdout.restore();
    stderr.restore();

    throw error;
  }

  return {exit, stderr: stderr.restore(), stdout: stdout.restore()};
};

export const read = (...segments: string[]): string =>
  readFileSync(path.join(...segments), 'utf8');

/** A route module's default export: its page, rendered in one line. */
export const ONE_LINE_RENDER = /^const \w+Route = \(\) => <\w+Page \/>;$/mu;

const listFilesRecursively = (dir: string): string[] =>
  readdirSync(dir, {recursive: true, withFileTypes: true})
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name));

/**
 * The lint boundary forbids `app/pages` importing `app/routes`, type-only
 * imports included, and exempts only stories and tests. A regression fails
 * `pnpm lint` in an adopter tree alone, so the suites check it here.
 */
export const expectNoRouteImports = (pageDir: string): void => {
  const sources = listFilesRecursively(pageDir).filter(
    (file) => !file.endsWith('.stories.tsx')
  );

  expect(sources.length).toBeGreaterThan(0);

  for (const file of sources) {
    expect(readFileSync(file, 'utf8')).not.toMatch(/from '~\/routes/u);
  }
};

export const ITEMS_PARSERS = `import {z} from 'zod';

export const itemSchema = z.object({
  id: z.string(),
  displayName: z.string(),
  count: z.number(),
  done: z.boolean(),
  status: z.literal(['open', 'closed']),
  notes: z.string().nullish(),
});

export const itemsSchema = z.array(itemSchema);

export const itemInputSchema = itemSchema.omit({id: true});
`;

const ITEMS_REQUESTS = `import {envelope, api} from '../api';
import {ITEMS_URLS} from './urls';
import {itemSchema, itemsSchema} from './parsers';
import type {Item, ItemInput, Items} from './types';

export const getAllItems = async (signal?: AbortSignal): Promise<Items> => {
  const {data} = await api(ITEMS_URLS.items, {schema: envelope(itemsSchema), signal});

  return data;
};

export const getItemById = async (id: string, signal?: AbortSignal): Promise<Item> => {
  const {data} = await api(ITEMS_URLS.itemsId, {pathParams: {id}, schema: envelope(itemSchema), signal});

  return data;
};

export const createItem = async (input: ItemInput, signal?: AbortSignal): Promise<Item> => {
  const {data} = await api(ITEMS_URLS.items, {json: input, method: 'post', schema: envelope(itemSchema), signal});

  return data;
};

export const updateItem = async (id: string, input: ItemInput, signal?: AbortSignal): Promise<Item> => {
  const {data} = await api(ITEMS_URLS.itemsId, {json: input, method: 'put', pathParams: {id}, schema: envelope(itemSchema), signal});

  return data;
};
`;

const ITEMS_QUERIES = `import {queryOptions} from '@tanstack/react-query';
import {getAllItems, getItemById} from './requests';

const ITEMS_ROOT_KEY = ['items'] as const;

export const itemKeys = {
  all: ITEMS_ROOT_KEY,
  detail: (id: string) => [...ITEMS_ROOT_KEY, 'detail', id] as const,
  list: () => [...ITEMS_ROOT_KEY, 'list'] as const,
};

export const itemsQuery = () =>
  queryOptions({queryFn: ({signal}) => getAllItems(signal), queryKey: itemKeys.list()});

export const itemQuery = (id: string) =>
  queryOptions({queryFn: ({signal}) => getItemById(id, signal), queryKey: itemKeys.detail(id)});
`;

type ServiceFixtureOptions = {
  /** Writes `useSnakeCase: false` into the layer's `api.ts`. */
  camelCaseWire?: boolean;
  /** `parsers.ts` contents; omitted writes the items schema above. */
  parsers?: string;
  /** Writes `queries.ts` into the service folder. */
  queries?: boolean;
  /** Declares `@tanstack/react-query` in `package.json`. */
  query?: boolean;
};

/** Writes `app/services/gaia/items/` and the package manifest under `packageDir`. */
export const writeItemsService = (
  packageDir: string,
  options: ServiceFixtureOptions = {}
): string => {
  const layerDir = path.join(packageDir, 'app', 'services', 'gaia');
  const serviceDir = path.join(layerDir, 'items');

  mkdirSync(serviceDir, {recursive: true});
  mkdirSync(path.join(packageDir, 'app', 'services', 'api'), {recursive: true});
  writeFileSync(
    path.join(layerDir, 'api.ts'),
    `export const api = create(${options.camelCaseWire === true ? '{useSnakeCase: false}' : ''});\n`
  );
  writeFileSync(
    path.join(serviceDir, 'parsers.ts'),
    options.parsers ?? ITEMS_PARSERS
  );
  writeFileSync(path.join(serviceDir, 'requests.ts'), ITEMS_REQUESTS);
  writeFileSync(
    path.join(serviceDir, 'urls.ts'),
    "export const ITEMS_URLS = {items: 'items', itemsId: 'items/:id'} as const;\n"
  );

  if (options.queries === true) {
    writeFileSync(path.join(serviceDir, 'queries.ts'), ITEMS_QUERIES);
  }

  writeFileSync(
    path.join(packageDir, 'package.json'),
    JSON.stringify({
      dependencies:
        options.query === true ? {'@tanstack/react-query': '5.104.1'} : {},
      name: 'frontend',
    })
  );

  return serviceDir;
};
