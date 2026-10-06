import ts from 'typescript';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  dataLayerTemplatePath,
  TANSTACK_QUERY_PACKAGE,
  TANSTACK_QUERY_VERSION,
} from '../scaffold/data-layer.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {run} from './configure-data-layer.js';
import {readState} from './util/state.js';

const FRONTEND = path.join(
  resolveRepoRootFromImportMeta(import.meta.url),
  'frontend'
);

const COPIED_FILES = [
  'app/root.tsx',
  'app/services/gaia/api.ts',
  'app/state/index.tsx',
  '.storybook/preview.ts',
  'package.json',
  'react-router.config.ts',
  'vite.config.ts',
  'vitest.config.ts',
];

const UNTOUCHED_WITHOUT_QUERY = [
  'app/root.tsx',
  'app/state/index.tsx',
  'package.json',
  'react-router.config.ts',
];

type Result = {changed: string[]; code: number; errors: string; next: string[]};

let root = '';
let stdout: string[] = [];
let stderr: string[] = [];

const rootPath = (relative: string): string => path.join(root, relative);

const read = (relative: string): string =>
  readFileSync(rootPath(relative), 'utf8');

const write = (relative: string, content: string): void => {
  mkdirSync(path.dirname(rootPath(relative)), {recursive: true});
  writeFileSync(rootPath(relative), content, 'utf8');
};

const snapshot = (): Record<string, string> => {
  const files: Record<string, string> = {};

  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir)) {
      const full = path.join(dir, entry);

      if (statSync(full).isDirectory()) walk(full);
      else if (!full.endsWith('init-state.json')) {
        files[path.relative(root, full)] = readFileSync(full, 'utf8');
      }
    }
  };

  walk(root);

  return files;
};

const configure = (...args: string[]): Result => {
  stdout = [];
  stderr = [];
  const code = run(args, {cwd: root});
  const line = stdout.join('').trim();
  const parsed =
    line.startsWith('{') ?
      (JSON.parse(line) as {changed: string[]; next: string[]})
    : {changed: [], next: []};

  return {...parsed, code, errors: stderr.join('')};
};

const createCallArgument = (source: string): ts.Expression | undefined => {
  const file = ts.createSourceFile(
    'api.ts',
    source,
    ts.ScriptTarget.Latest,
    true
  );
  let found: ts.Expression | undefined;
  let seen = false;

  const visit = (node: ts.Node): void => {
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === 'create'
    ) {
      seen = true;
      [found] = node.arguments;
    }
    ts.forEachChild(node, visit);
  };

  visit(file);
  expect(seen).toBe(true);

  return found;
};

const useSnakeCaseValue = (source: string): string | undefined => {
  const argument = createCallArgument(source);

  if (argument === undefined || !ts.isObjectLiteralExpression(argument))
    return undefined;
  const property = argument.properties.find(
    (entry): entry is ts.PropertyAssignment =>
      ts.isPropertyAssignment(entry) && entry.name.getText() === 'useSnakeCase'
  );

  return property?.initializer.getText();
};

beforeEach(() => {
  root = mkdtempSync(path.join(tmpdir(), 'gaia-init-configure-data-layer-'));
  writeFrontendRegistry(root);

  for (const relative of COPIED_FILES) {
    mkdirSync(path.dirname(rootPath(relative)), {recursive: true});
    cpSync(path.join(FRONTEND, relative), rootPath(relative));
  }
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    stdout.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
    stderr.push(String(chunk));

    return true;
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

describe('flag errors', () => {
  test.each([
    [[]],
    [['--bogus', 'x']],
    [['--casing', 'kebab']],
    [['--query', 'maybe']],
    [['--layer', 'gaia']],
  ])('%j exits 1', (args) => {
    expect(configure(...args).code).toBe(1);
  });
});

describe('query off', () => {
  test('casing snake changes nothing and leaves the owned files byte-identical', () => {
    const before = snapshot();
    const result = configure('--casing', 'snake', '--query', 'false');

    expect(result.code).toBe(0);
    expect(result.changed).toEqual([]);

    for (const relative of UNTOUCHED_WITHOUT_QUERY) {
      expect(read(relative)).toBe(before[relative]);
    }
  });

  test('records the step with null for omitted flags', () => {
    configure('--query', 'false');

    expect(readState(root).step_args['configure-data-layer']).toEqual({
      casing: null,
      layer: null,
      query: false,
    });
  });
});

describe('query on', () => {
  test('pins the exact version, writes the runtime, wraps the stock State, and leaves root alone', () => {
    const before = snapshot();
    const result = configure('--query', 'true');

    expect(result.code).toBe(0);
    expect(result.next).toContain('pnpm install');
    expect(result.changed).toEqual(
      result.changed.toSorted((a, b) => a.localeCompare(b))
    );

    const pkg = JSON.parse(read('package.json')) as {
      dependencies: Record<string, string>;
    };

    expect(pkg.dependencies[TANSTACK_QUERY_PACKAGE]).toBe(
      TANSTACK_QUERY_VERSION
    );
    expect(TANSTACK_QUERY_VERSION).toMatch(/^\d/u);

    const templates: [string, string][] = [
      ['query-client.ts.tmpl', 'app/query-client.ts'],
      ['query-provider.tsx.tmpl', 'app/state/query-provider.tsx'],
      [
        'QueryClientDecorator.tsx.tmpl',
        '.storybook/decorators/QueryClientDecorator.tsx',
      ],
    ];

    for (const [template, target] of templates) {
      expect(read(target)).toBe(
        readFileSync(dataLayerTemplatePath(template), 'utf8')
      );
    }

    expect(read('app/state/index.tsx')).toContain(
      '<QueryProvider>{children}</QueryProvider>'
    );
    expect(read('app/state/index.tsx')).toContain(
      "import QueryProvider from './query-provider';"
    );
    expect(read('.storybook/preview.ts')).toContain('QueryClientDecorator');
    expect(read('vite.config.ts')).toContain(`'${TANSTACK_QUERY_PACKAGE}',`);
    expect(read('vitest.config.ts')).toContain(`'${TANSTACK_QUERY_PACKAGE}',`);
    expect(read('app/root.tsx')).toBe(before['app/root.tsx']);
    expect(read('react-router.config.ts')).toBe(
      before['react-router.config.ts']
    );
  });

  test('a second run changes nothing, and --query false never removes Query', () => {
    configure('--query', 'true');
    const afterFirst = snapshot();
    const second = configure('--query', 'true');

    expect(second.code).toBe(0);
    expect(second.changed).toEqual([]);
    expect(snapshot()).toEqual(afterFirst);

    const off = configure('--query', 'false');

    expect(off.changed).toEqual([]);
    expect(snapshot()).toEqual(afterFirst);
  });

  test('the optimizeDeps entry lands in sorted position', () => {
    configure('--query', 'true');
    const include = read('vite.config.ts')
      .split('\n')
      .map((line) => /^\s*'([^']+)',$/u.exec(line)?.[1])
      .filter((name): name is string => name !== undefined);
    const at = include.indexOf(TANSTACK_QUERY_PACKAGE);

    expect(at).toBeGreaterThan(0);
    expect(include[at - 1]! < TANSTACK_QUERY_PACKAGE).toBe(true);
    expect(include[at + 1]! > TANSTACK_QUERY_PACKAGE).toBe(true);
  });

  test('never overwrites an existing runtime file', () => {
    write('app/query-client.ts', '// adopter version\n');
    configure('--query', 'true');

    expect(read('app/query-client.ts')).toBe('// adopter version\n');
  });
});

describe('casing', () => {
  test('only camel adds useSnakeCase: false', () => {
    for (const casing of ['snake', 'sdk', 'unsure']) {
      configure('--casing', casing);
      expect(
        createCallArgument(read('app/services/gaia/api.ts'))
      ).toBeUndefined();
    }
    expect(existsSync(rootPath('app/services/gaia/api.ts'))).toBe(true);

    const result = configure('--casing', 'camel');

    expect(result.code).toBe(0);
    expect(useSnakeCaseValue(read('app/services/gaia/api.ts'))).toBe('false');
    expect(result.changed).toEqual(['app/services/gaia/api.ts']);
    expect(configure('--casing', 'camel').changed).toEqual([]);
  });

  test('sets an existing useSnakeCase to false and adds it to an object literal', () => {
    write(
      'app/services/gaia/api.ts',
      "import {create} from '../api';\n\nexport const api = create({useSnakeCase: true});\n"
    );
    configure('--casing', 'camel');
    expect(useSnakeCaseValue(read('app/services/gaia/api.ts'))).toBe('false');

    write(
      'app/services/gaia/api.ts',
      "import {create} from '../api';\n\nexport const api = create({arrayFormat: 'comma'});\n"
    );
    configure('--casing', 'camel');
    expect(useSnakeCaseValue(read('app/services/gaia/api.ts'))).toBe('false');
    expect(read('app/services/gaia/api.ts')).toContain("arrayFormat: 'comma'");
  });

  test('refuses an api.ts with no create() call', () => {
    write('app/services/gaia/api.ts', 'export const api = 1;\n');
    const result = configure('--casing', 'camel');

    expect(result.code).toBe(1);
    expect(result.errors).toContain('data_layer_anchor_missing');
  });

  test('refuses camel when the layer is ambiguous and names --layer', () => {
    mkdirSync(rootPath('app/services/other'), {recursive: true});
    const result = configure('--casing', 'camel');

    expect(result.code).toBe(1);
    expect(result.errors).toContain('--layer');
  });
});

describe('anchors', () => {
  test('a customized State and a preview with a decorators array apply cleanly and rerun clean', () => {
    write(
      'app/state/index.tsx',
      "import type {ReactNode} from 'react';\nimport Other from './other';\n\nconst State = ({children}: {children: ReactNode}) => (\n  <Other>{children}</Other>\n);\n\nexport default State;\n"
    );
    write(
      '.storybook/preview.ts',
      "import Foo from './foo';\n\nconst preview = {\n  decorators: [Foo],\n};\n\nexport default preview;\n"
    );
    const first = configure('--query', 'true');

    expect(first.code).toBe(0);
    expect(read('app/state/index.tsx')).toContain(
      '<Other><QueryProvider>{children}</QueryProvider></Other>'
    );
    expect(read('.storybook/preview.ts')).toContain(
      'decorators: [Foo, QueryClientDecorator],'
    );
    expect(configure('--query', 'true').changed).toEqual([]);
  });

  test.each([
    [
      'app/state/index.tsx',
      'const State = ({children}) => <><A>{children}</A><B>{children}</B></>;\n',
    ],
    ['.storybook/preview.ts', 'const preview = {};\nexport default preview;\n'],
    ['vite.config.ts', 'export default {};\n'],
  ])('%s without its anchor exits 1 and writes nothing', (file, content) => {
    write(file, content);
    const before = snapshot();
    const result = configure('--query', 'true');

    expect(result.code).toBe(1);
    expect(result.errors).toContain('data_layer_anchor_missing');
    expect(result.errors).toContain(file);
    expect(snapshot()).toEqual(before);
  });
});

describe('--queries-only hints', () => {
  test('hints a service with both getters and no queries.ts, and skips a post-only service', () => {
    write(
      'app/services/gaia/items/requests.ts',
      'export const getAllItems = async () => [];\nexport const getItemById = async (id: string) => id;\n'
    );
    write(
      'app/services/gaia/widgets/requests.ts',
      'export const createWidget = async () => null;\n'
    );
    const result = configure('--query', 'true');

    expect(result.next).toContain(
      './.gaia/cli/gaia scaffold service items --queries-only --layer gaia'
    );
    expect(result.next.some((command) => command.includes('widgets'))).toBe(
      false
    );

    write('app/services/gaia/items/queries.ts', 'export {};\n');
    expect(configure('--query', 'true').next).toEqual([]);
  });

  test('applies the scaffold getter names, so generic getters of another name get no hint', () => {
    write(
      'app/services/gaia/items/requests.ts',
      'export const getAllWidgets = async () => [];\nexport const getWidgetById = async (id: string) => id;\n'
    );
    write(
      'app/services/gaia/tasks/requests.ts',
      'export const getAllTasks = async () => [];\nexport const getTaskById = async (id: string) => id;\n'
    );
    const {next} = configure('--query', 'true');

    expect(
      next.filter((command) => command.includes('--queries-only'))
    ).toEqual([
      './.gaia/cli/gaia scaffold service tasks --queries-only --layer gaia',
    ]);
  });
});
