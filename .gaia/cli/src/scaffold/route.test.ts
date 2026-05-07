import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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
import {fileURLToPath} from 'node:url';
import {run} from './route.js';

/**
 * The route handler resolves the repo root from `import.meta.url`. To
 * exercise the handler against an isolated tree we mirror the same depth
 * (`<root>/.gaia/cli/src/scaffold/`) inside a temp dir, plant `app/` at
 * the mirrored root, and `chdir` so the relative scaffold paths resolve
 * deterministically.
 */
type Sandbox = {
  cleanup: () => void;
  fakeRoot: string;
};

const HERE = fileURLToPath(import.meta.url);
const TEMPLATES_DIR = path.join(path.dirname(HERE), 'templates', 'route');
const ROUTE_HANDLER_DEPTH_FROM_ROOT = ['.gaia', 'cli', 'src', 'scaffold'];

/**
 * Construct a temporary "repo root" with a mirrored `.gaia/cli/src/scaffold/`
 * directory containing copies of the route templates. The handler resolves
 * its template directory and repo root via `import.meta.url`; we stub
 * `import.meta.url` by spying on `fileURLToPath` is brittle, so instead we
 * test the handler by directly constructing inputs that match its
 * `repoRoot()` calculation. We do that by chdir-ing — but the handler does
 * not use cwd. Instead, we test the handler by invoking it with a
 * monkey-patched module path is overkill. Use a simpler strategy: spy on
 * `fileURLToPath` is hard since it's read at module load.
 *
 * Pragmatic alternative: write the inputs the handler will write to under
 * the real repo (a subfolder we own), assert outputs, then clean up. We
 * keep this test scoped to the temp scaffold directory by parameterizing
 * the handler indirectly through a minimal in-process integration: use a
 * subprocess of the actual handler with `--json` and an isolated `cwd`
 * that has the right structure.
 *
 * Implementation: spawn a fresh module load of `route.ts` with patched
 * `import.meta.url` is not feasible via plain vi mocks. Instead, since
 * `route.ts` derives root from `import.meta.url` once per call (inside
 * `repoRoot()`), we mock `node:url`'s `fileURLToPath` for the duration of
 * each test to return a controlled path that puts the handler's "root" at
 * our temp dir.
 */

vi.mock('node:url', async () => {
  const actual = await vi.importActual<typeof import('node:url')>('node:url');

  return {
    ...actual,
    fileURLToPath: (input: string | URL): string => {
      const real = actual.fileURLToPath(input);
      const override = (globalThis as {__gaiaRouteRoot?: string})
        .__gaiaRouteRoot;

      if (override !== undefined && real.includes('/scaffold/')) {
        return path.join(
          override,
          ...ROUTE_HANDLER_DEPTH_FROM_ROOT,
          'route.ts'
        );
      }

      return real;
    },
  };
});

const setupSandbox = (): Sandbox => {
  const fakeRoot = mkdtempSync(path.join(tmpdir(), 'gaia-route-'));
  const scaffoldDir = path.join(
    fakeRoot,
    ...ROUTE_HANDLER_DEPTH_FROM_ROOT,
    'templates',
    'route'
  );
  mkdirSync(scaffoldDir, {recursive: true});

  // Copy real templates into the sandbox so renderTemplate can read them.
  const templates = [
    'route.tsx.tmpl',
    'page.index.tsx.tmpl',
    'page.test.tsx.tmpl',
    'page.stories.tsx.tmpl',
    'locale.ts.tmpl',
  ];

  for (const tmpl of templates) {
    const source = path.join(TEMPLATES_DIR, tmpl);
    const dest = path.join(scaffoldDir, tmpl);
    writeFileSync(dest, readFileSync(source, 'utf8'), 'utf8');
  }

  (globalThis as {__gaiaRouteRoot?: string}).__gaiaRouteRoot = fakeRoot;

  return {
    cleanup: () => {
      delete (globalThis as {__gaiaRouteRoot?: string}).__gaiaRouteRoot;
      rmSync(fakeRoot, {force: true, recursive: true});
    },
    fakeRoot,
  };
};

const captureStdout = (): {restore: () => string} => {
  const chunks: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: unknown): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  }) as typeof process.stdout.write;

  return {
    restore: (): string => {
      process.stdout.write = original;

      return chunks.join('');
    },
  };
};

const captureStderr = (): {restore: () => string} => {
  const chunks: string[] = [];
  const original = process.stderr.write.bind(process.stderr);
  process.stderr.write = ((chunk: unknown): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  }) as typeof process.stderr.write;

  return {
    restore: (): string => {
      process.stderr.write = original;

      return chunks.join('');
    },
  };
};

const seedLocaleBarrel = (fakeRoot: string, body: string): string => {
  const dir = path.join(fakeRoot, 'app', 'languages', 'en', 'pages');
  mkdirSync(dir, {recursive: true});
  const filePath = path.join(dir, 'index.ts');
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

describe('scaffold route — argument validation', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('rejects missing --group', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard']);
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('--group is required');
  });

  test('rejects invalid --group value', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_admin+']);
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('--group must be one of');
  });

  test('rejects non-kebab name', () => {
    const stderr = captureStderr();
    const exit = run(['Dashboard', '--group', '_session+']);
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('kebab-case');
  });

  test('rejects unknown flag', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_session+', '--bogus']);
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('invalid or unknown flag');
  });

  test('prints help when invoked with no args', () => {
    const stdout = captureStdout();
    const exit = run([]);
    stdout.restore();

    expect(exit).toBe(1);
  });
});

describe('scaffold route — base emission (_session+)', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits route file, page index, test, and story', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+']);
    stdout.restore();

    expect(exit).toBe(0);

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'dashboard.tsx'
    );
    const pageIndex = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'Dashboard',
      'index.tsx'
    );
    const pageTest = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'Dashboard',
      'tests',
      'index.test.tsx'
    );
    const pageStories = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'Dashboard',
      'tests',
      'index.stories.tsx'
    );

    expect(existsSync(routeFile)).toBe(true);
    expect(existsSync(pageIndex)).toBe(true);
    expect(existsSync(pageTest)).toBe(true);
    expect(existsSync(pageStories)).toBe(true);

    const routeBody = readFileSync(routeFile, 'utf8');
    expect(routeBody).toContain("import Dashboard from '~/pages/Session/Dashboard'");
    expect(routeBody).toContain('const DashboardRoute');
    expect(routeBody).not.toContain('export const loader');
    expect(routeBody).not.toContain('export const action');

    const pageBody = readFileSync(pageIndex, 'utf8');
    expect(pageBody).toContain('const Dashboard: FC');
    expect(pageBody).toContain('export default Dashboard');

    const storiesBody = readFileSync(pageStories, 'utf8');
    expect(storiesBody).toContain('Pages/Session/Dashboard');
  });

  test('hyphenated names map to PascalCase folder', () => {
    const stdout = captureStdout();
    const exit = run(['user-settings', '--group', '_session+']);
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'UserSettings',
      'index.tsx'
    );
    expect(existsSync(pageIndex)).toBe(true);

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'user-settings.tsx'
    );
    const routeBody = readFileSync(routeFile, 'utf8');
    expect(routeBody).toContain('const UserSettingsRoute');
  });

  test('_public+ group writes to Public segment', () => {
    const stdout = captureStdout();
    const exit = run(['marketing', '--group', '_public+']);
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Public',
      'Marketing',
      'index.tsx'
    );
    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_public+',
      'marketing.tsx'
    );
    expect(existsSync(pageIndex)).toBe(true);
    expect(existsSync(routeFile)).toBe(true);
  });
});

describe('scaffold route — flag combos', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('--loader emits loader export', () => {
    const stdout = captureStdout();
    run(['dashboard', '--group', '_session+', '--loader']);
    stdout.restore();

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'dashboard.tsx'
    );
    const body = readFileSync(routeFile, 'utf8');
    expect(body).toContain('export const loader');
    expect(body).toContain('useLoaderData');
    expect(body).toContain("from './+types/dashboard'");
  });

  test('--action emits action export', () => {
    const stdout = captureStdout();
    run(['dashboard', '--group', '_session+', '--action']);
    stdout.restore();

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'dashboard.tsx'
    );
    const body = readFileSync(routeFile, 'utf8');
    expect(body).toContain('export const action');
    expect(body).toContain('Route.ActionArgs');
  });

  test('--loader and --action together', () => {
    const stdout = captureStdout();
    run(['dashboard', '--group', '_session+', '--loader', '--action']);
    stdout.restore();

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'dashboard.tsx'
    );
    const body = readFileSync(routeFile, 'utf8');
    expect(body).toContain('export const loader');
    expect(body).toContain('export const action');
  });

  test('--i18n with existing barrel inserts alphabetically', () => {
    const barrelPath = seedLocaleBarrel(
      sandbox.fakeRoot,
      [
        "import index from './_index';",
        "import legal from './legal';",
        '',
        'export default {',
        '  index,',
        '  legal,',
        '};',
        '',
      ].join('\n')
    );

    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+', '--i18n']);
    stdout.restore();

    expect(exit).toBe(0);

    const localeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'languages',
      'en',
      'pages',
      'Dashboard',
      'index.ts'
    );
    expect(existsSync(localeFile)).toBe(true);
    const localeBody = readFileSync(localeFile, 'utf8');
    expect(localeBody).toContain("description: 'Description of the dashboard page'");
    expect(localeBody).toContain("title: 'Dashboard'");

    const after = readFileSync(barrelPath, 'utf8');
    expect(after).toContain("import dashboard from './Dashboard';");

    // Alphabetical: dashboard < index < legal by import-name comparison.
    const lines = after.split('\n');
    const importLines = lines.filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import dashboard from './Dashboard';",
      "import index from './_index';",
      "import legal from './legal';",
    ]);

    // Default-export block updated.
    expect(after).toMatch(/dashboard,\s*\n\s*index,\s*\n\s*legal,/u);

    const pageBody = readFileSync(
      path.join(
        sandbox.fakeRoot,
        'app',
        'pages',
        'Session',
        'Dashboard',
        'index.tsx'
      ),
      'utf8'
    );
    expect(pageBody).toContain("useTranslation('pages', {keyPrefix: 'dashboard'})");
  });

  test('--json emits a single ScaffoldResult JSON line', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+', '--json']);
    const out = stdout.restore();

    expect(exit).toBe(0);
    const parsed = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(parsed).toHaveProperty('written');
    expect(parsed).toHaveProperty('edited');
    expect(parsed).toHaveProperty('skipped');
    expect(Array.isArray(parsed['written'])).toBe(true);
  });
});

describe('scaffold route — idempotency', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('second invocation with same args is a no-op (no throws, files unchanged)', () => {
    const stdout1 = captureStdout();
    const exit1 = run(['dashboard', '--group', '_session+']);
    stdout1.restore();
    expect(exit1).toBe(0);

    const routeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'routes',
      '_session+',
      'dashboard.tsx'
    );
    const before = readFileSync(routeFile, 'utf8');

    const stdout2 = captureStdout();
    const exit2 = run(['dashboard', '--group', '_session+']);
    stdout2.restore();

    expect(exit2).toBe(0);
    const after = readFileSync(routeFile, 'utf8');
    expect(after).toBe(before);
  });

  test('barrel insert is idempotent on re-run', () => {
    const barrelPath = seedLocaleBarrel(
      sandbox.fakeRoot,
      [
        "import index from './_index';",
        '',
        'export default {',
        '  index,',
        '};',
        '',
      ].join('\n')
    );

    const stdout1 = captureStdout();
    run(['dashboard', '--group', '_session+', '--i18n']);
    stdout1.restore();

    const afterFirst = readFileSync(barrelPath, 'utf8');

    const stdout2 = captureStdout();
    run(['dashboard', '--group', '_session+', '--i18n']);
    stdout2.restore();

    const afterSecond = readFileSync(barrelPath, 'utf8');
    expect(afterFirst).toBe(afterSecond);

    const occurrences = afterSecond.match(/import dashboard from/gu);
    expect(occurrences).toHaveLength(1);
  });
});

describe('scaffold route — barrel alphabetical insert correctness', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('inserts before lex-larger first import (new entry at top of imports)', () => {
    const barrelPath = seedLocaleBarrel(
      sandbox.fakeRoot,
      [
        "import legal from './legal';",
        '',
        'export default {',
        '  legal,',
        '};',
        '',
      ].join('\n')
    );

    const stdout = captureStdout();
    run(['admin', '--group', '_session+', '--i18n']);
    stdout.restore();

    const after = readFileSync(barrelPath, 'utf8');
    const importLines = after
      .split('\n')
      .filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import admin from './Admin';",
      "import legal from './legal';",
    ]);
  });

  test('appends after lex-smaller last import (new entry at bottom of imports)', () => {
    const barrelPath = seedLocaleBarrel(
      sandbox.fakeRoot,
      [
        "import admin from './Admin';",
        "import legal from './legal';",
        '',
        'export default {',
        '  admin,',
        '  legal,',
        '};',
        '',
      ].join('\n')
    );

    const stdout = captureStdout();
    run(['zone', '--group', '_session+', '--i18n']);
    stdout.restore();

    const after = readFileSync(barrelPath, 'utf8');
    const importLines = after
      .split('\n')
      .filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import admin from './Admin';",
      "import legal from './legal';",
      "import zone from './Zone';",
    ]);
  });
});
