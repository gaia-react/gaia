/**
 * vitest coverage for `gaia scaffold service`.
 *
 * Each test runs the handler against a sandbox repo seeded to mirror the real
 * shape (`app/services/gaia/`, `test/mocks/database.ts` with the empty
 * default-export). We assert on file presence, file contents, and the
 * idempotence contract.
 */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run} from './service.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const seedDatabase = (root: string): string => {
  const databaseDirectory = path.join(root, 'test', 'mocks');
  mkdirSync(databaseDirectory, {recursive: true});
  const databasePath = path.join(databaseDirectory, 'database.ts');
  writeFileSync(
    databasePath,
    [
      '// Barrel for `@msw/data` collections.',
      '',
      'export const resetTestData = async (): Promise<void> => {};',
      '',
      'export default {} as Record<string, never>;',
      '',
    ].join('\n'),
    'utf8'
  );

  return databasePath;
};

const setupSandbox = ({withDatabase}: {withDatabase: boolean}): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-service-'));
  writeFrontendRegistry(dir);
  mkdirSync(path.join(dir, 'app', 'services', 'gaia'), {recursive: true});

  if (withDatabase) seedDatabase(dir);

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

const itemsDir = (root: string): string =>
  path.join(root, 'app', 'services', 'gaia', 'items');

const scaffoldItems = (root: string, extra: string[] = []): number =>
  run(
    [
      'items',
      '--endpoints',
      'get,post,put,delete',
      '--schema',
      'id:string,displayName:string',
      ...extra,
    ],
    {cwd: root}
  );

const scaffoldGetPost = (root: string): number =>
  run(
    [
      'items',
      '--endpoints',
      'get,post',
      '--schema',
      'id:string,displayName:string',
    ],
    {cwd: root}
  );

const installQuery = (root: string): void => {
  writeFileSync(
    path.join(root, 'package.json'),
    JSON.stringify({dependencies: {'@tanstack/react-query': '5.104.1'}}),
    'utf8'
  );
};

const captureStderr = (action: () => number): {code: number; err: string} => {
  let err = '';
  const originalWrite = process.stderr.write.bind(process.stderr);

  (process.stderr as any).write = (chunk: string | Uint8Array): boolean => {
    err +=
      typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');

    return true;
  };

  try {
    return {code: action(), err};
  } finally {
    process.stderr.write = originalWrite;
  }
};

describe('gaia scaffold service', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox({withDatabase: true});
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits 5 service files plus 4 mock files for projects with --mocks (get,post)', () => {
    const code = run(
      [
        'projects',
        '--endpoints',
        'get,post',
        '--schema',
        'id:string,title:string',
        '--mocks',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.OK);

    const serviceDir = path.join(
      sandbox.dir,
      'app',
      'services',
      'gaia',
      'projects'
    );
    expect(existsSync(path.join(serviceDir, 'parsers.ts'))).toBe(true);
    expect(existsSync(path.join(serviceDir, 'types.ts'))).toBe(true);
    expect(existsSync(path.join(serviceDir, 'requests.ts'))).toBe(true);
    expect(existsSync(path.join(serviceDir, 'urls.ts'))).toBe(true);
    expect(existsSync(path.join(serviceDir, 'index.ts'))).toBe(true);

    const mockDir = path.join(sandbox.dir, 'test', 'mocks', 'projects');
    expect(existsSync(path.join(mockDir, 'data.ts'))).toBe(true);
    expect(existsSync(path.join(mockDir, 'get.ts'))).toBe(true);
    expect(existsSync(path.join(mockDir, 'post.ts'))).toBe(true);
    expect(existsSync(path.join(mockDir, 'index.ts'))).toBe(true);
    // Endpoints not requested must NOT be emitted.
    expect(existsSync(path.join(mockDir, 'put.ts'))).toBe(false);
    expect(existsSync(path.join(mockDir, 'delete.ts'))).toBe(false);

    // database.ts must have been edited.
    const database = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    expect(database).toContain(
      "import {projects, resetProjects} from './projects/data';"
    );
    expect(database).toContain('resetProjects()');
    expect(database).toContain('export default {projects};');
  });

  test('--endpoints "get" emits only the get request and the get mock', () => {
    const code = run(
      [
        'things',
        '--endpoints',
        'get',
        '--schema',
        'id:string,name:string',
        '--mocks',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.OK);

    const serviceDir = path.join(
      sandbox.dir,
      'app',
      'services',
      'gaia',
      'things'
    );
    const requests = read(path.join(serviceDir, 'requests.ts'));
    expect(requests).toContain('getAllThings');
    expect(requests).toContain('getThingById');
    expect(requests).not.toContain('createThing');
    expect(requests).not.toContain('updateThing');
    expect(requests).not.toContain('deleteThing');

    const urls = read(path.join(serviceDir, 'urls.ts'));
    expect(urls).toContain("things: 'things'");
    expect(urls).toContain("thingsId: 'things/:id'");

    const mockDir = path.join(sandbox.dir, 'test', 'mocks', 'things');
    expect(existsSync(path.join(mockDir, 'get.ts'))).toBe(true);
    expect(existsSync(path.join(mockDir, 'post.ts'))).toBe(false);
    expect(existsSync(path.join(mockDir, 'put.ts'))).toBe(false);
    expect(existsSync(path.join(mockDir, 'delete.ts'))).toBe(false);

    const barrel = read(path.join(mockDir, 'index.ts'));
    expect(barrel).toContain("import get from './get';");
    expect(barrel).not.toContain("import post from './post';");
    expect(barrel).not.toContain("import put from './put';");
    expect(barrel).not.toContain("import del from './delete';");
    expect(barrel).toContain('const handlers = [...get];');
  });

  test('--schema with enum produces z.literal + TS union', () => {
    const code = run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string,status:enum(active,archived)',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.OK);

    const parsers = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );
    expect(parsers).toContain("status: z.literal(['active', 'archived'])");

    const types = read(
      path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects', 'types.ts')
    );
    // The TS type is derived via z.infer, so the union is implicit; what we
    // verify here is that the type alias points at the schema.
    expect(types).toContain('z.infer<typeof projectSchema>');
  });

  test('optional types append .nullish()', () => {
    run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string,description:string?',
      ],
      {cwd: sandbox.dir}
    );

    const parsers = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );
    expect(parsers).toContain('description: z.string().nullish()');
  });

  test('re-run is idempotent: files unchanged, no duplicate barrel inserts', () => {
    const args = [
      'projects',
      '--endpoints',
      'get,post',
      '--schema',
      'id:string,title:string',
      '--mocks',
    ];
    expect(run(args, {cwd: sandbox.dir})).toBe(EXIT_CODES.OK);
    const databaseAfterFirst = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    const parsersAfterFirst = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );

    expect(run(args, {cwd: sandbox.dir})).toBe(EXIT_CODES.OK);
    const databaseAfterSecond = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    const parsersAfterSecond = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'parsers.ts'
      )
    );

    expect(databaseAfterSecond).toBe(databaseAfterFirst);
    expect(parsersAfterSecond).toBe(parsersAfterFirst);
    // No duplicate import lines.
    const importMatches =
      databaseAfterSecond.match(/import \{projects, resetProjects\}/gu) ?? [];
    expect(importMatches).toHaveLength(1);
  });

  test('without --mocks: only 5 service files; no mock dir; database untouched', () => {
    const databasePath = path.join(sandbox.dir, 'test', 'mocks', 'database.ts');
    const before = read(databasePath);

    const code = run(
      ['projects', '--endpoints', 'get', '--schema', 'id:string'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.OK);

    const serviceDir = path.join(
      sandbox.dir,
      'app',
      'services',
      'gaia',
      'projects'
    );
    expect(existsSync(path.join(serviceDir, 'parsers.ts'))).toBe(true);
    expect(existsSync(path.join(serviceDir, 'index.ts'))).toBe(true);

    const mockDir = path.join(sandbox.dir, 'test', 'mocks', 'projects');
    expect(existsSync(mockDir)).toBe(false);

    expect(read(databasePath)).toBe(before);
  });

  test('database.ts collection insert is alphabetical', () => {
    // Pre-seed the database with two existing collections, then add `mango`
    // (between apples and zebras) and confirm position.
    const databasePath = path.join(sandbox.dir, 'test', 'mocks', 'database.ts');
    writeFileSync(
      databasePath,
      [
        "import {apples, resetApples} from './apples/data';",
        "import {zebras, resetZebras} from './zebras/data';",
        '',
        'export const resetTestData = async (): Promise<void> => {',
        '  await Promise.all([resetApples(), resetZebras()]);',
        '};',
        '',
        'export default {apples, zebras};',
        '',
      ].join('\n'),
      'utf8'
    );

    const code = run(
      ['mangoes', '--endpoints', 'get', '--schema', 'id:string', '--mocks'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.OK);

    const after = read(databasePath);
    const importLines = after
      .split('\n')
      .filter((line) => line.startsWith('import {'));
    expect(importLines).toEqual([
      "import {apples, resetApples} from './apples/data';",
      "import {mangoes, resetMangoes} from './mangoes/data';",
      "import {zebras, resetZebras} from './zebras/data';",
    ]);

    expect(after).toContain(
      'Promise.all([resetApples(), resetMangoes(), resetZebras()])'
    );
    expect(after).toContain('export default {apples, mangoes, zebras}');
  });

  test('fails loudly when the database barrel is missing the Promise.all region', () => {
    // A barrel whose `resetTestData` lost its `Promise.all([...])` region:
    // the import insert applies but the reset-call insert can no longer
    // match. The diff-safety net must reject this instead of writing a
    // half-applied barrel.
    const databasePath = path.join(sandbox.dir, 'test', 'mocks', 'database.ts');
    writeFileSync(
      databasePath,
      [
        "import {apples, resetApples} from './apples/data';",
        '',
        'export const resetTestData = async (): Promise<void> => {',
        '  // resetting disabled',
        '};',
        '',
        'export default {apples};',
        '',
      ].join('\n'),
      'utf8'
    );

    const code = run(
      ['mangoes', '--endpoints', 'get', '--schema', 'id:string', '--mocks'],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);

    // The barrel must be left untouched; no partial write.
    const after = read(databasePath);
    expect(after).not.toContain('mangoes');
    // The barrel edit is planned before anything is written, so the refusal
    // leaves no service or mock files behind either.
    expect(
      existsSync(path.join(sandbox.dir, 'app', 'services', 'gaia', 'mangoes'))
    ).toBe(false);
    expect(existsSync(path.join(sandbox.dir, 'test', 'mocks', 'mangoes'))).toBe(
      false
    );
  });

  test('stock empty barrel gains a Promise.all with the new reset call', () => {
    const databasePath = path.join(sandbox.dir, 'test', 'mocks', 'database.ts');

    expect(scaffoldItems(sandbox.dir, ['--mocks'])).toBe(EXIT_CODES.OK);

    const after = read(databasePath);
    expect(after).toContain(
      'export const resetTestData = async (): Promise<void> => {\n  await Promise.all([resetItems()]);\n};'
    );
    expect(after).toContain('export default {items};');
  });

  test('hand-registered sequential resets fold into one Promise.all', () => {
    const databasePath = path.join(sandbox.dir, 'test', 'mocks', 'database.ts');
    writeFileSync(
      databasePath,
      [
        "import {apples, resetApples} from './apples/data';",
        '',
        'export const resetTestData = async (): Promise<void> => {',
        '  await resetApples();',
        '};',
        '',
        'export default {apples};',
        '',
      ].join('\n'),
      'utf8'
    );

    const code = run(
      ['mangoes', '--endpoints', 'get', '--schema', 'id:string', '--mocks'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.OK);

    const after = read(databasePath);
    expect(after).toContain(
      'await Promise.all([resetApples(), resetMangoes()]);'
    );
    expect(after).not.toContain('await resetApples();');
    expect(after).toContain('export default {apples, mangoes};');
  });

  test('--json emits a single ScaffoldResult JSON line', () => {
    let captured = '';
    const originalWrite = process.stdout.write.bind(process.stdout);

    (process.stdout as any).write = (chunk: string | Uint8Array): boolean => {
      captured +=
        typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');

      return true;
    };

    try {
      const code = run(
        ['projects', '--endpoints', 'get', '--schema', 'id:string', '--json'],
        {cwd: sandbox.dir}
      );
      expect(code).toBe(EXIT_CODES.OK);
    } finally {
      process.stdout.write = originalWrite;
    }

    const lines = captured.trim().split('\n');
    const lastLine = lines.at(-1) ?? '';
    const parsed = JSON.parse(lastLine) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };
    expect(parsed.written.length).toBeGreaterThan(0);
    expect(Array.isArray(parsed.edited)).toBe(true);
    expect(Array.isArray(parsed.skipped)).toBe(true);
  });

  test('rejects non-kebab name', () => {
    const code = run(
      ['BadName', '--endpoints', 'get', '--schema', 'id:string'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('rejects missing --endpoints', () => {
    const code = run(['projects', '--schema', 'id:string'], {cwd: sandbox.dir});
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('rejects missing --schema', () => {
    const code = run(['projects', '--endpoints', 'get'], {cwd: sandbox.dir});
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('rejects unknown endpoint token', () => {
    const code = run(
      ['projects', '--endpoints', 'get,patch', '--schema', 'id:string'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('rejects unknown schema type', () => {
    const code = run(
      ['projects', '--endpoints', 'get', '--schema', 'id:bigint'],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('full CRUD emits all four request functions and full mock barrel', () => {
    const code = run(
      [
        'projects',
        '--endpoints',
        'get,post,put,delete',
        '--schema',
        'id:string,title:string',
        '--mocks',
      ],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.OK);

    const requests = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'projects',
        'requests.ts'
      )
    );
    expect(requests).toContain('getAllProjects');
    expect(requests).toContain('createProject');
    expect(requests).toContain('updateProject');
    expect(requests).toContain('deleteProject');

    const barrel = read(
      path.join(sandbox.dir, 'test', 'mocks', 'projects', 'index.ts')
    );
    expect(barrel).toContain("import del from './delete';");
    expect(barrel).toContain("import get from './get';");
    expect(barrel).toContain("import post from './post';");
    expect(barrel).toContain("import put from './put';");
    expect(barrel).toContain('const handlers = [...get, post, put, del];');
  });

  test('camelCase field name is converted to snake_case in mock data schema', () => {
    run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string,createdAt:datetime',
        '--mocks',
      ],
      {cwd: sandbox.dir}
    );
    const mockData = read(
      path.join(sandbox.dir, 'test', 'mocks', 'projects', 'data.ts')
    );
    expect(mockData).toContain('created_at: z.iso.datetime()');
  });

  test('multi-word kebab name derives correct identifiers', () => {
    run(['user-settings', '--endpoints', 'get', '--schema', 'id:string'], {
      cwd: sandbox.dir,
    });
    const urls = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'user-settings',
        'urls.ts'
      )
    );
    expect(urls).toContain('USER_SETTINGS_URLS');
    expect(urls).toContain("userSettings: 'user-settings'");
    expect(urls).toContain("userSettingsId: 'user-settings/:id'");

    const types = read(
      path.join(
        sandbox.dir,
        'app',
        'services',
        'gaia',
        'user-settings',
        'types.ts'
      )
    );
    expect(types).toContain('UserSetting');
    expect(types).toContain('UserSettings');
  });

  test('writes into a renamed domain-layer folder and points mocks at it', () => {
    const servicesDir = path.join(sandbox.dir, 'app', 'services');
    rmSync(path.join(servicesDir, 'gaia'), {force: true, recursive: true});
    mkdirSync(path.join(servicesDir, 'acme'), {recursive: true});
    mkdirSync(path.join(servicesDir, 'api'), {recursive: true});

    const code = run(
      ['projects', '--endpoints', 'get', '--schema', 'id:string', '--mocks'],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.OK);
    expect(
      existsSync(path.join(servicesDir, 'acme', 'projects', 'urls.ts'))
    ).toBe(true);
    expect(existsSync(path.join(servicesDir, 'gaia'))).toBe(false);
    expect(
      read(path.join(sandbox.dir, 'test', 'mocks', 'projects', 'get.ts'))
    ).toContain("from '~/services/acme/projects/urls'");
  });

  test('refuses to guess when several domain-layer folders exist', () => {
    const servicesDir = path.join(sandbox.dir, 'app', 'services');
    mkdirSync(path.join(servicesDir, 'acme'), {recursive: true});

    const code = run(
      ['projects', '--endpoints', 'get', '--schema', 'id:string'],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(existsSync(path.join(servicesDir, 'gaia', 'projects'))).toBe(false);
    expect(existsSync(path.join(servicesDir, 'acme', 'projects'))).toBe(false);
  });

  test('--layer picks the folder when several exist', () => {
    const servicesDir = path.join(sandbox.dir, 'app', 'services');
    mkdirSync(path.join(servicesDir, 'acme'), {recursive: true});

    const code = run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
        '--layer',
        'acme',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.OK);
    expect(
      existsSync(path.join(servicesDir, 'acme', 'projects', 'urls.ts'))
    ).toBe(true);
  });

  test('rejects a --layer that names a file, not a folder', () => {
    const servicesDir = path.join(sandbox.dir, 'app', 'services');
    writeFileSync(path.join(servicesDir, 'notes'), '');

    const code = run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
        '--layer',
        'notes',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(existsSync(path.join(servicesDir, 'notes', 'projects'))).toBe(false);
  });

  test('rejects a --layer that is not one folder name', () => {
    const code = run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
        '--layer',
        '../escape',
      ],
      {cwd: sandbox.dir}
    );

    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  describe('request contract', () => {
    test('requests.ts validates through envelope, sends JSON, and threads signal', () => {
      expect(scaffoldItems(sandbox.dir)).toBe(EXIT_CODES.OK);
      const requests = read(path.join(itemsDir(sandbox.dir), 'requests.ts'));

      expect(requests).toContain("import {api, envelope} from '../api';");
      expect(requests).toContain('envelope(itemsSchema)');
      expect(requests).toContain('envelope(itemSchema)');
      expect(requests).toContain('json: input');
      expect(requests).toContain('signal');
      expect(requests).toContain(
        'export const updateItem = async (\n  id: string,\n  input: ItemInput,'
      );
      expect(requests).toContain(
        'export const deleteItem = async (\n  id: string,\n  signal?: AbortSignal\n): Promise<void> =>'
      );
      expect(requests).not.toMatch(/\.parse\(/u);
      expect(requests).not.toMatch(/api</u);
      expect(requests).not.toMatch(/ as /u);
      expect(requests).not.toContain('FormData');
    });

    test('a delete-only service imports no unused envelope or parsers', () => {
      const code = run(
        ['items', '--endpoints', 'delete', '--schema', 'id:string'],
        {cwd: sandbox.dir}
      );
      const requests = read(path.join(itemsDir(sandbox.dir), 'requests.ts'));

      expect(code).toBe(EXIT_CODES.OK);
      expect(requests).toContain("import {api} from '../api';");
      expect(requests).not.toContain('envelope');
      expect(requests).not.toContain('./parsers');
    });

    test('input schema omits id when the schema has one', () => {
      scaffoldItems(sandbox.dir);
      const parsers = read(path.join(itemsDir(sandbox.dir), 'parsers.ts'));
      const types = read(path.join(itemsDir(sandbox.dir), 'types.ts'));

      expect(parsers).toContain(
        'itemInputSchema = itemSchema.omit({id: true});'
      );
      expect(types).toContain('export type ItemInput');
    });

    test('input schema is the entity schema when there is no id', () => {
      const code = run(
        ['items', '--endpoints', 'post', '--schema', 'displayName:string'],
        {cwd: sandbox.dir}
      );

      expect(code).toBe(EXIT_CODES.OK);
      expect(read(path.join(itemsDir(sandbox.dir), 'parsers.ts'))).toContain(
        'itemInputSchema = itemSchema;'
      );
    });

    test('parsers.ts keeps one field per line as "  <name>: <zod>,"', () => {
      scaffoldItems(sandbox.dir);
      const parsers = read(path.join(itemsDir(sandbox.dir), 'parsers.ts'));
      const block = /z\.object\(\{\n([\s\S]*?)\}\);/u.exec(parsers)?.[1];

      expect(block?.split('\n').filter(Boolean)).toEqual([
        '  id: z.string(),',
        '  displayName: z.string(),',
      ]);
    });

    test('mock post and put read the JSON body, not form data', () => {
      scaffoldItems(sandbox.dir, ['--mocks']);
      const mockDir = path.join(sandbox.dir, 'test', 'mocks', 'items');
      const post = read(path.join(mockDir, 'post.ts'));
      const put = read(path.join(mockDir, 'put.ts'));

      expect(post).toContain('request.json()');
      expect(post).toContain('crypto.randomUUID()');
      expect(post).not.toContain('formData');
      expect(put).toContain('request.json()');
      expect(put).not.toContain('formData');
    });

    // `@msw/data`'s `delete`, `deleteMany`, and `findMany` are synchronous,
    // so awaiting them fails `await-thenable` in the adopter's lint, as do a
    // sequential await loop and a redundant `undefined` argument.
    test('mock data, get, and delete call the collection the way its types allow', () => {
      scaffoldItems(sandbox.dir, ['--mocks']);
      const mockDir = path.join(sandbox.dir, 'test', 'mocks', 'items');
      const data = read(path.join(mockDir, 'data.ts'));
      const get = read(path.join(mockDir, 'get.ts'));
      const del = read(path.join(mockDir, 'delete.ts'));

      expect(data).toContain('items.clear();');
      expect(data).toContain(
        'await Promise.all(seed.map(async (record) => items.create(record)));'
      );
      expect(data).not.toMatch(/for \(|await items\.delete/u);
      expect(get).toContain('items.findMany()');
      expect(del).toContain('const data = items.delete(');
      expect(del).not.toContain('async');
    });
  });

  describe('TanStack Query', () => {
    test('writes queries.ts when Query is installed', () => {
      installQuery(sandbox.dir);
      expect(scaffoldGetPost(sandbox.dir)).toBe(EXIT_CODES.OK);
      const queries = read(path.join(itemsDir(sandbox.dir), 'queries.ts'));

      expect(queries).toContain('export const itemKeys');
      expect(queries).toContain('all: ITEMS_ROOT_KEY');
      expect(queries).toContain('detail: (id: string)');
      expect(queries).toContain(
        'queryFn: async ({signal}) => getItemById(id, signal)'
      );
      expect(queries).toContain(
        'queryFn: async ({signal}) => getAllItems(signal)'
      );
      // Every exported factory names its return type, which
      // `explicit-module-boundary-types` requires under app/services/**.
      expect(queries).toContain(
        'export const itemsQuery = (): ReturnType<typeof listOptions> =>'
      );
      expect(queries).toContain(
        'export const itemQuery = (id: string): ReturnType<typeof detailOptions> =>'
      );
      expect(read(path.join(itemsDir(sandbox.dir), 'index.ts'))).not.toContain(
        'queries'
      );
    });

    test('writes no queries.ts without the dependency', () => {
      expect(scaffoldGetPost(sandbox.dir)).toBe(EXIT_CODES.OK);
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        false
      );
    });

    test('writes no queries.ts when the service has no get endpoint', () => {
      installQuery(sandbox.dir);
      const code = run(
        ['items', '--endpoints', 'post', '--schema', 'id:string'],
        {cwd: sandbox.dir}
      );

      expect(code).toBe(EXIT_CODES.OK);
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        false
      );
    });

    test('--queries-only writes only queries.ts and leaves the rest byte-identical', () => {
      scaffoldGetPost(sandbox.dir);
      const files = [
        'parsers.ts',
        'types.ts',
        'requests.ts',
        'urls.ts',
        'index.ts',
      ];
      const before = files.map((file) =>
        read(path.join(itemsDir(sandbox.dir), file))
      );
      installQuery(sandbox.dir);

      expect(run(['items', '--queries-only'], {cwd: sandbox.dir})).toBe(
        EXIT_CODES.OK
      );
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        true
      );
      expect(
        files.map((file) => read(path.join(itemsDir(sandbox.dir), file)))
      ).toEqual(before);
    });

    test('--queries-only refuses without Query and names the install command', () => {
      scaffoldGetPost(sandbox.dir);
      const {code, err} = captureStderr(() =>
        run(['items', '--queries-only'], {cwd: sandbox.dir})
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(err).toContain('init configure-data-layer --query true');
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        false
      );
    });

    test('--queries-only refuses a missing service folder', () => {
      installQuery(sandbox.dir);
      const {code} = captureStderr(() =>
        run(['items', '--queries-only'], {cwd: sandbox.dir})
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(existsSync(itemsDir(sandbox.dir))).toBe(false);
    });

    test('--queries-only refuses when requests.ts lacks the by-id getter', () => {
      scaffoldGetPost(sandbox.dir);
      writeFileSync(
        path.join(itemsDir(sandbox.dir), 'requests.ts'),
        'export const getAllItems = async () => [];\n',
        'utf8'
      );
      installQuery(sandbox.dir);
      const {code, err} = captureStderr(() =>
        run(['items', '--queries-only'], {cwd: sandbox.dir})
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(err).toContain('getItemById');
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        false
      );
    });

    test('--queries-only refuses --endpoints and --schema', () => {
      scaffoldGetPost(sandbox.dir);
      installQuery(sandbox.dir);
      const {code} = captureStderr(() =>
        run(['items', '--queries-only', '--endpoints', 'get'], {
          cwd: sandbox.dir,
        })
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(existsSync(path.join(itemsDir(sandbox.dir), 'queries.ts'))).toBe(
        false
      );
    });
  });
});
