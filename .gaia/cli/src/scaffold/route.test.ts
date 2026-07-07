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
import {run} from './route.js';

/**
 * The route handler resolves output paths from an injectable `cwd` (default
 * `process.cwd()`) and reads its templates from the module location. We point
 * `cwd` at a fresh temp dir so the scaffolded `app/` tree lands in isolation,
 * and let the real shipped templates render unchanged.
 */
type Sandbox = {
  cleanup: () => void;
  fakeRoot: string;
};

const setupSandbox = (): Sandbox => {
  const fakeRoot = mkdtempSync(path.join(tmpdir(), 'gaia-route-'));

  return {
    cleanup: () => {
      rmSync(fakeRoot, {force: true, recursive: true});
    },
    fakeRoot,
  };
};

const captureStdout = (): {restore: () => string} => {
  const chunks: string[] = [];
  const original = process.stdout.write.bind(process.stdout);

  process.stdout.write = (chunk: unknown): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  };

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

  process.stderr.write = (chunk: unknown): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  };

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

describe('scaffold route: argument validation', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('rejects missing --group', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard'], {cwd: sandbox.fakeRoot});
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('--group is required');
  });

  test('rejects invalid --group value', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_admin+'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('--group must be one of');
  });

  test('rejects non-kebab name', () => {
    const stderr = captureStderr();
    const exit = run(['Dashboard', '--group', '_session+'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('kebab-case');
  });

  test('rejects unknown flag', () => {
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_session+', '--bogus'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('invalid or unknown flag');
  });

  test('prints help when invoked with no args', () => {
    const stdout = captureStdout();
    const exit = run([], {cwd: sandbox.fakeRoot});
    stdout.restore();

    expect(exit).toBe(1);
  });
});

describe('scaffold route: base emission (_session+)', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits route file, page index, test, and story', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+'], {
      cwd: sandbox.fakeRoot,
    });
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
      'DashboardPage',
      'index.tsx'
    );
    const pageTest = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'DashboardPage',
      'tests',
      'index.test.tsx'
    );
    const pageStories = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'DashboardPage',
      'tests',
      'index.stories.tsx'
    );

    expect(existsSync(routeFile)).toBe(true);
    expect(existsSync(pageIndex)).toBe(true);
    expect(existsSync(pageTest)).toBe(true);
    expect(existsSync(pageStories)).toBe(true);

    const routeBody = readFileSync(routeFile, 'utf8');
    expect(routeBody).toContain(
      "import DashboardPage from '~/pages/Session/DashboardPage'"
    );
    expect(routeBody).toContain('const DashboardRoute');
    expect(routeBody).not.toContain('export const loader');
    expect(routeBody).not.toContain('export const action');

    const pageBody = readFileSync(pageIndex, 'utf8');
    expect(pageBody).toContain('const DashboardPage: FC');
    expect(pageBody).toContain('export default DashboardPage');

    const storiesBody = readFileSync(pageStories, 'utf8');
    expect(storiesBody).toContain('Pages/Session/DashboardPage');
  });

  test('hyphenated names map to <Pascal>Page folder', () => {
    const stdout = captureStdout();
    const exit = run(['user-settings', '--group', '_session+'], {
      cwd: sandbox.fakeRoot,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Session',
      'UserSettingsPage',
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
    expect(routeBody).toContain(
      "import UserSettingsPage from '~/pages/Session/UserSettingsPage'"
    );
  });

  test('_public+ group writes to Public segment', () => {
    const stdout = captureStdout();
    const exit = run(['marketing', '--group', '_public+'], {
      cwd: sandbox.fakeRoot,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const pageIndex = path.join(
      sandbox.fakeRoot,
      'app',
      'pages',
      'Public',
      'MarketingPage',
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

describe('scaffold route: flag combos', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('--loader emits loader export', () => {
    const stdout = captureStdout();
    run(['dashboard', '--group', '_session+', '--loader'], {
      cwd: sandbox.fakeRoot,
    });
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
    run(['dashboard', '--group', '_session+', '--action'], {
      cwd: sandbox.fakeRoot,
    });
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
    run(['dashboard', '--group', '_session+', '--loader', '--action'], {
      cwd: sandbox.fakeRoot,
    });
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
    const exit = run(['dashboard', '--group', '_session+', '--i18n'], {
      cwd: sandbox.fakeRoot,
    });
    stdout.restore();

    expect(exit).toBe(0);

    const localeFile = path.join(
      sandbox.fakeRoot,
      'app',
      'languages',
      'en',
      'pages',
      'dashboard.ts'
    );
    expect(existsSync(localeFile)).toBe(true);
    const localeBody = readFileSync(localeFile, 'utf8');
    expect(localeBody).toContain(
      "description: 'Description of the dashboard page'"
    );
    expect(localeBody).toContain("title: 'DashboardPage'");

    const after = readFileSync(barrelPath, 'utf8');
    expect(after).toContain("import dashboard from './dashboard';");

    // Alphabetical: dashboard < index < legal by import-name comparison.
    const lines = after.split('\n');
    const importLines = lines.filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import dashboard from './dashboard';",
      "import index from './_index';",
      "import legal from './legal';",
    ]);

    // Default-export block updated. `[ \t]*\n[ \t]*` (not `\s*\n\s*`, whose
    // `\s` already matches `\n` and overlaps with the literal that follows)
    // avoids sonarjs/super-linear-regex's overlapping-quantifier shape.
    expect(after).toMatch(
      /dashboard,[ \t]*\n[ \t]*index,[ \t]*\n[ \t]*legal,/u
    );

    const pageBody = readFileSync(
      path.join(
        sandbox.fakeRoot,
        'app',
        'pages',
        'Session',
        'DashboardPage',
        'index.tsx'
      ),
      'utf8'
    );
    expect(pageBody).toContain(
      "useTranslation('pages', {keyPrefix: 'dashboard'})"
    );
  });

  test('--i18n with a missing barrel surfaces the failure', () => {
    // No barrel seeded: the locale file is written but cannot be wired.
    const stderr = captureStderr();
    const exit = run(['dashboard', '--group', '_session+', '--i18n'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stderr.restore();

    expect(exit).toBe(1);
    expect(out).toContain('locale barrel not found');
  });

  test('--json emits a single ScaffoldResult JSON line', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+', '--json'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stdout.restore();

    expect(exit).toBe(0);
    const parsed = JSON.parse(out.trim()) as Record<string, unknown>;
    expect(parsed).toHaveProperty('written');
    expect(parsed).toHaveProperty('edited');
    expect(parsed).toHaveProperty('skipped');
    expect(Array.isArray(parsed.written)).toBe(true);
  });
});

describe('scaffold route: --dry-run', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('reports would-be writes without touching the filesystem', () => {
    const stdout = captureStdout();
    const exit = run(['dashboard', '--group', '_session+', '--dry-run'], {
      cwd: sandbox.fakeRoot,
    });
    const out = stdout.restore();

    expect(exit).toBe(0);
    expect(out).toContain('dry-run: no files written');
    expect(out).toContain('would write');

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
      'DashboardPage',
      'index.tsx'
    );
    expect(existsSync(routeFile)).toBe(false);
    expect(existsSync(pageIndex)).toBe(false);
  });

  test('--dry-run is orthogonal to --json and writes nothing', () => {
    const barrelBody = [
      "import index from './_index';",
      '',
      'export default {',
      '  index,',
      '};',
      '',
    ].join('\n');
    const barrelPath = seedLocaleBarrel(sandbox.fakeRoot, barrelBody);

    const stdout = captureStdout();
    const exit = run(
      ['dashboard', '--group', '_session+', '--i18n', '--dry-run', '--json'],
      {cwd: sandbox.fakeRoot}
    );
    const out = stdout.restore();

    expect(exit).toBe(0);

    const parsed = JSON.parse(out.trim()) as {
      edited: string[];
      written: string[];
    };
    expect(parsed.written.length).toBeGreaterThan(0);
    expect(parsed.edited).toContain(barrelPath);

    // The barrel is reported as a would-be edit but stays untouched on disk.
    expect(readFileSync(barrelPath, 'utf8')).toBe(barrelBody);
    expect(
      existsSync(
        path.join(
          sandbox.fakeRoot,
          'app',
          'languages',
          'en',
          'pages',
          'dashboard.ts'
        )
      )
    ).toBe(false);
  });
});

describe('scaffold route: idempotency', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('second invocation with same args is a no-op (no throws, files unchanged)', () => {
    const stdout1 = captureStdout();
    const exit1 = run(['dashboard', '--group', '_session+'], {
      cwd: sandbox.fakeRoot,
    });
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
    const exit2 = run(['dashboard', '--group', '_session+'], {
      cwd: sandbox.fakeRoot,
    });
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
    run(['dashboard', '--group', '_session+', '--i18n'], {
      cwd: sandbox.fakeRoot,
    });
    stdout1.restore();

    const afterFirst = readFileSync(barrelPath, 'utf8');

    const stdout2 = captureStdout();
    run(['dashboard', '--group', '_session+', '--i18n'], {
      cwd: sandbox.fakeRoot,
    });
    stdout2.restore();

    const afterSecond = readFileSync(barrelPath, 'utf8');
    expect(afterFirst).toBe(afterSecond);

    const occurrences = afterSecond.match(/import dashboard from/gu);
    expect(occurrences).toHaveLength(1);
  });
});

describe('scaffold route: barrel alphabetical insert correctness', () => {
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
    run(['admin', '--group', '_session+', '--i18n'], {cwd: sandbox.fakeRoot});
    stdout.restore();

    const after = readFileSync(barrelPath, 'utf8');
    const importLines = after
      .split('\n')
      .filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import admin from './admin';",
      "import legal from './legal';",
    ]);
  });

  test('appends after lex-smaller last import (new entry at bottom of imports)', () => {
    const barrelPath = seedLocaleBarrel(
      sandbox.fakeRoot,
      [
        "import admin from './admin';",
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
    run(['zone', '--group', '_session+', '--i18n'], {cwd: sandbox.fakeRoot});
    stdout.restore();

    const after = readFileSync(barrelPath, 'utf8');
    const importLines = after
      .split('\n')
      .filter((line) => /^import\s/u.test(line));
    expect(importLines).toEqual([
      "import admin from './admin';",
      "import legal from './legal';",
      "import zone from './zone';",
    ]);
  });
});
