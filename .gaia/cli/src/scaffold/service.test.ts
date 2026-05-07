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
      'export const resetTestData = async (): Promise<void> => {',
      '  await Promise.all([]);',
      '};',
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

    const serviceDir = path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects');
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
    const database = read(path.join(sandbox.dir, 'test', 'mocks', 'database.ts'));
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

    const serviceDir = path.join(sandbox.dir, 'app', 'services', 'gaia', 'things');
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

  test('--schema with enum produces z.enum + TS union', () => {
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
      path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects', 'parsers.ts')
    );
    expect(parsers).toContain("status: z.enum(['active', 'archived'])");

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
      path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects', 'parsers.ts')
    );
    expect(parsers).toContain('description: z.string().nullish()');
  });

  test('re-run is idempotent — files unchanged, no duplicate barrel inserts', () => {
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
      path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects', 'parsers.ts')
    );

    expect(run(args, {cwd: sandbox.dir})).toBe(EXIT_CODES.OK);
    const databaseAfterSecond = read(
      path.join(sandbox.dir, 'test', 'mocks', 'database.ts')
    );
    const parsersAfterSecond = read(
      path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects', 'parsers.ts')
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

    const serviceDir = path.join(sandbox.dir, 'app', 'services', 'gaia', 'projects');
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
      [
        'mangoes',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
        '--mocks',
      ],
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

  test('--json emits a single ScaffoldResult JSON line', () => {
    let captured = '';
    const originalWrite = process.stdout.write.bind(process.stdout);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (process.stdout as any).write = (chunk: string | Uint8Array): boolean => {
      captured +=
        typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');

      return true;
    };

    try {
      const code = run(
        [
          'projects',
          '--endpoints',
          'get',
          '--schema',
          'id:string',
          '--json',
        ],
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
      [
        'BadName',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
      ],
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
      [
        'projects',
        '--endpoints',
        'get,patch',
        '--schema',
        'id:string',
      ],
      {cwd: sandbox.dir}
    );
    expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });

  test('rejects unknown schema type', () => {
    const code = run(
      [
        'projects',
        '--endpoints',
        'get',
        '--schema',
        'id:bigint',
      ],
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
    run(
      [
        'user-settings',
        '--endpoints',
        'get',
        '--schema',
        'id:string',
      ],
      {cwd: sandbox.dir}
    );
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
});
