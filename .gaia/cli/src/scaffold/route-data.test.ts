import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  test,
} from 'vitest';
import {existsSync, mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  expectNoRouteImports,
  ONE_LINE_RENDER,
  read,
  scaffold,
  setupSandbox,
  writeItemsService,
} from './route-fixture.js';
import type {Sandbox} from './route-fixture.js';

/** The body of the exported const `name`, up to the next top-level close. */
const exportBody = (source: string, name: string): string => {
  const start = source.indexOf(`export const ${name} =`);

  expect(start).toBeGreaterThan(-1);

  const end = source.indexOf('\n};', start);

  expect(end).toBeGreaterThan(start);

  return source.slice(start, end);
};

type DataCase = {
  absent: readonly string[];
  data: 'client' | 'query' | 'server';
  dataRead: string;
  hasFallback: boolean;
  mutationCall: string;
  pagePath: readonly string[];
  present: readonly string[];
  routeFile: string;
  shape: 'detail' | 'list';
  shapeMarker: RegExp;
  storyHandler: string;
  storyStart: string;
};

const LIST = {
  mutationCall: 'createItem(submission.value)',
  pagePath: ['items'],
  routeFile: '_public.items.tsx',
  shape: 'list',
  shapeMarker: /<Link className="underline" to=\{`\/items\/\$\{item\.id\}`\}>/u,
  storyHandler: 'http.post(',
  storyStart: "path: '/',",
} as const;

const DETAIL = {
  mutationCall: 'updateItem(params.id, submission.value)',
  pagePath: ['items', 'id'],
  routeFile: '_public.items_.$id.tsx',
  shape: 'detail',
  shapeMarker: /defaultValue: item,/u,
  storyHandler: 'http.put(',
  storyStart: "initialEntry: '/items/1',",
} as const;

const SERVER = {
  absent: ['export const clientLoader', 'export const HydrateFallback'],
  data: 'server',
  dataRead: 'useLoaderData<LoaderData>()',
  hasFallback: false,
  present: ['export const loader', 'export const action'],
} as const;

const CLIENT = {
  absent: ['export const loader', 'export const clientAction'],
  data: 'client',
  dataRead: 'useLoaderData<LoaderData>()',
  hasFallback: true,
  present: [
    'export const clientLoader',
    'export const HydrateFallback',
    'export const action',
  ],
} as const;

const QUERY = {
  absent: ['export const loader', 'export const action ='],
  data: 'query',
  dataRead: 'useSuspenseQuery(',
  hasFallback: true,
  present: [
    'export const clientLoader',
    'export const HydrateFallback',
    'export const clientAction',
  ],
} as const;

const CASES: DataCase[] = [SERVER, CLIENT, QUERY].flatMap((variant) =>
  [LIST, DETAIL].map((shape) => ({...variant, ...shape}))
);

const scaffoldCase = (root: string, dataCase: DataCase): void => {
  const result = scaffold(root, [
    'items',
    '--group',
    '_public',
    '--data',
    dataCase.data,
    '--service',
    'items',
    '--shape',
    dataCase.shape,
    '--action',
  ]);

  expect(result.exit).toBe(0);
};

const pageDirOf = (root: string, dataCase: DataCase): string =>
  path.join(root, 'app', 'pages', ...dataCase.pagePath);

const routeOf = (root: string, dataCase: DataCase): string =>
  read(root, 'app', 'routes', dataCase.routeFile);

describe.each(CASES)('scaffold route --data: $data $shape', (dataCase) => {
  let sandbox: Sandbox;

  beforeAll(() => {
    sandbox = setupSandbox('gaia-route-data-');
    writeItemsService(sandbox.root, {queries: true, query: true});
    scaffoldCase(sandbox.root, dataCase);
  });

  afterAll(() => {
    sandbox.cleanup();
  });

  test('the route module exports its data functions and renders one line', () => {
    const route = routeOf(sandbox.root, dataCase);

    for (const exported of dataCase.present) {
      expect(route).toContain(exported);
    }

    for (const exported of dataCase.absent) {
      expect(route).not.toContain(exported);
    }

    expect(route).toMatch(ONE_LINE_RENDER);
    expect(route).not.toContain('useLoaderData');
    expect(route).not.toContain('useSuspenseQuery');
    expect(route).not.toContain('useState');
    expect(route).not.toContain('.hydrate');
  });

  test('the action validates and passes on only the parsed value', () => {
    const route = routeOf(sandbox.root, dataCase);

    expect(route).toContain("import {parseWithZod} from '@conform-to/zod/v4';");
    expect(route).toContain('schema: itemInputSchema');
    expect(route).toContain(`await ${dataCase.mutationCall};`);
    expect(route).toContain("return redirect('/items');");
  });

  test('the page reads the data and owns the head and form', () => {
    const pageDir = pageDirOf(sandbox.root, dataCase);
    const page = read(pageDir, 'page.tsx');

    expect(page).toContain(dataCase.dataRead);
    expect(page).toMatch(dataCase.shapeMarker);
    expect(page).toContain('<title>');
    expect(page).toContain('name="description"');
    expect(page).toContain('parseWithZod(formData, {schema: itemInputSchema})');
    expect(page).toContain("getInputProps(fields.displayName, {type: 'text'})");
    expect(page).toContain("getInputProps(fields.count, {type: 'number'})");
    expect(page).toContain('<Checkbox');
    expect(page).not.toContain('fields.id');
    expect(
      existsSync(path.join(pageDir, 'hydrate-fallback', 'index.tsx'))
    ).toBe(dataCase.hasFallback);
    expectNoRouteImports(pageDir);
  });

  test('the page story serves MSW data and checks the wire body', () => {
    const story = read(
      pageDirOf(sandbox.root, dataCase),
      'tests',
      'page.stories.tsx'
    );

    expect(story).toContain("from 'msw/http'");
    expect(story).not.toContain("from 'msw';");
    expect(story).toContain('handlers: [');
    expect(story).toContain('stubs.reactRouter({');
    expect(story).toContain("destinations: ['/items'],");
    expect(story).toContain(dataCase.storyStart);
    expect(story).toContain(dataCase.storyHandler);
    expect(story).toContain('.play = async');
    expect(story).toContain('submittedBody = await request.json();');
    expect(story).toContain("await canvas.findByText('Navigated to /items')");
    // The wire carries the camelCase default keys, which the play checks the handler got.
    expect(story).toContain("displayName: 'Display name 2',");
  });

  if (dataCase.data === 'query') {
    test('clientLoader fills the cache and clientAction invalidates before redirecting', () => {
      const route = routeOf(sandbox.root, dataCase);
      const clientLoader = exportBody(route, 'clientLoader');
      const clientAction = exportBody(route, 'clientAction');
      const queryCall =
        dataCase.shape === 'list' ? 'itemsQuery()' : 'itemQuery(params.id)';

      expect(clientLoader).toContain(
        `await getQueryClient().query(${queryCall});`
      );
      expect(clientLoader).not.toContain('return');
      expect(clientAction).toContain(
        'await getQueryClient().invalidateQueries({queryKey: itemKeys.all});'
      );
      expect(clientAction.indexOf('invalidateQueries(')).toBeLessThan(
        clientAction.indexOf('redirect(')
      );
      expect(
        existsSync(path.join(pageDirOf(sandbox.root, dataCase), 'types.ts'))
      ).toBe(false);
    });
  } else {
    test('the loader data type lives in the page folder', () => {
      const route = routeOf(sandbox.root, dataCase);

      expect(route).toContain(
        `import type {LoaderData} from '~/pages/${dataCase.pagePath.join('/')}/types';`
      );
      expect(route).toContain('Promise<LoaderData>');
      expect(read(pageDirOf(sandbox.root, dataCase), 'types.ts')).toContain(
        dataCase.shape === 'list' ? 'items: Items;' : 'item: Item;'
      );
    });
  }
});

describe('scaffold route --data: other flag combinations', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-data-');
    writeItemsService(sandbox.root, {queries: true, query: true});
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('a variant without --action reads data but writes no form or mutation', () => {
    const result = scaffold(sandbox.root, [
      'items',
      '--group',
      '_session',
      '--data',
      'client',
      '--service',
      'items',
      '--shape',
      'list',
    ]);

    expect(result.exit).toBe(0);

    const route = read(sandbox.root, 'app', 'routes', '_session.items.tsx');
    const pageDir = path.join(sandbox.root, 'app', 'pages', 'items');

    expect(route).not.toContain('export const action');
    expect(route).not.toContain('parseWithZod');
    expect(read(pageDir, 'page.tsx')).not.toContain('useForm');
    expect(read(pageDir, 'tests', 'page.stories.tsx')).not.toContain(
      'submittedBody'
    );
  });

  test('the layer opting into snake_case puts snake_case keys in the story', () => {
    writeItemsService(sandbox.root, {snakeCaseWire: true});

    const result = scaffold(sandbox.root, [
      'items',
      '--group',
      '_public',
      '--data',
      'server',
      '--service',
      'items',
      '--shape',
      'detail',
      '--action',
    ]);

    expect(result.exit).toBe(0);

    const story = read(
      sandbox.root,
      'app',
      'pages',
      'items',
      'id',
      'tests',
      'page.stories.tsx'
    );

    expect(story).toContain("display_name: 'Display name 2',");
    expect(story).not.toContain("displayName: 'Display name 2',");
  });

  test('--i18n on a detail route writes its own locale file and key', () => {
    const barrel = path.join(sandbox.root, 'app', 'languages', 'en', 'pages');

    mkdirSync(barrel, {recursive: true});
    writeFileSync(
      path.join(barrel, 'index.ts'),
      "import items from './items';\n\nexport default {\n  items,\n};\n"
    );

    const result = scaffold(sandbox.root, [
      'items',
      '--group',
      '_public',
      '--data',
      'client',
      '--service',
      'items',
      '--shape',
      'detail',
      '--i18n',
    ]);

    expect(result.exit).toBe(0);
    expect(read(barrel, 'index.ts')).toContain(
      "import itemsDetail from './items-detail';"
    );
    expect(read(barrel, 'items-detail.ts')).toContain(
      "displayName: 'Display name',"
    );
    expect(
      read(sandbox.root, 'app', 'pages', 'items', 'id', 'page.tsx')
    ).toContain("useTranslation('pages', {keyPrefix: 'itemsDetail'})");
  });
});

const dataArgs = (...extra: string[]): string[] => [
  'items',
  '--group',
  '_public',
  ...extra,
];

describe('scaffold route --data: refusals write nothing', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-route-data-');
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  const expectNothingWritten = (): void => {
    expect(existsSync(path.join(sandbox.root, 'app', 'routes'))).toBe(false);
    expect(existsSync(path.join(sandbox.root, 'app', 'pages'))).toBe(false);
  };

  test('--data query without TanStack Query names the init command', () => {
    writeItemsService(sandbox.root, {queries: true, query: false});

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'query', '--service', 'items', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('init configure-data-layer --query true');
    expectNothingWritten();
  });

  test.each(['client', 'query'])('--data %s with --loader', (data) => {
    writeItemsService(sandbox.root, {queries: true, query: true});

    const result = scaffold(
      sandbox.root,
      dataArgs(
        '--data',
        data,
        '--service',
        'items',
        '--shape',
        'list',
        '--loader'
      )
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('--loader does not combine with --data');
    expect(result.stderr).toContain('HydrateFallback');
    expectNothingWritten();
  });

  test('--data server without --service', () => {
    writeItemsService(sandbox.root);

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'server', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('--data needs --service');
    expectNothingWritten();
  });

  test('--shape without --data', () => {
    writeItemsService(sandbox.root);

    const result = scaffold(sandbox.root, dataArgs('--shape', 'list'));

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('pass --data');
    expectNothingWritten();
  });

  test('an unknown --data value', () => {
    writeItemsService(sandbox.root);

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'static', '--service', 'items', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('--data must be one of');
    expectNothingWritten();
  });

  test('a missing service folder', () => {
    writeItemsService(sandbox.root);

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'server', '--service', 'orders', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('service folder not found');
    expectNothingWritten();
  });

  test('an unreadable parsers.ts names the file and the expected shape', () => {
    writeItemsService(sandbox.root, {
      parsers: 'export const itemSchema = buildSchema();\n',
    });

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'server', '--service', 'items', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('app/services/gaia/items/parsers.ts');
    expect(result.stderr).toContain('export const itemSchema = z.object({');
    expectNothingWritten();
  });

  test('a field expression the scaffold cannot render is refused', () => {
    writeItemsService(sandbox.root, {
      parsers: [
        'export const itemSchema = z.object({',
        '  id: z.string(),',
        '  tags: z.array(z.string()),',
        '});',
        '',
        'export const itemInputSchema = itemSchema.omit({id: true});',
        '',
      ].join('\n'),
    });

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'server', '--service', 'items', '--shape', 'list')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('tags: z.array(z.string()),');
    expectNothingWritten();
  });

  test('--data query with a service that has no queries.ts names --queries-only', () => {
    writeItemsService(sandbox.root, {queries: false, query: true});

    const result = scaffold(
      sandbox.root,
      dataArgs('--data', 'query', '--service', 'items', '--shape', 'detail')
    );

    expect(result.exit).toBe(1);
    expect(result.stderr).toContain('scaffold service items --queries-only');
    expectNothingWritten();
  });
});
