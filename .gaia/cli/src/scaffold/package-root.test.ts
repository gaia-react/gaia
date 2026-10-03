import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {execGaiaGit} from '../util/git-env.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run as runComponent} from './component.js';
import {run as runHook} from './hook.js';
import {run as runRoute} from './route.js';
import {run as runService} from './service.js';

type Scaffolder = {
  /** Files the scaffolder writes, relative to the package directory. */
  expected: readonly string[];
  name: string;
  run: (cwd: string) => number;
  /** Directories that must exist in the package before it runs. */
  seed: readonly string[];
};

const SCAFFOLDERS: readonly Scaffolder[] = [
  {
    expected: ['app/components/Widget/index.tsx'],
    name: 'component',
    run: (cwd) => runComponent(['Widget', '--no-story'], {cwd}),
    seed: ['app/components'],
  },
  {
    expected: ['app/hooks/useWidget.ts'],
    name: 'hook',
    run: (cwd) => runHook(['useWidget'], {repoRoot: cwd}),
    seed: [],
  },
  {
    expected: ['app/routes/_public.widget.tsx'],
    name: 'route',
    run: (cwd) => runRoute(['widget', '--group', '_public'], {cwd}),
    seed: [],
  },
  {
    expected: [
      'app/services/gaia/widgets/parsers.ts',
      'test/mocks/widgets/index.ts',
    ],
    name: 'service',
    run: (cwd) =>
      runService(
        ['widgets', '--endpoints', 'get', '--schema', 'id:string', '--mocks'],
        {cwd}
      ),
    seed: ['app/services/gaia', 'test/mocks'],
  },
];

const listFiles = (directory: string): string[] =>
  readdirSync(directory, {recursive: true, withFileTypes: true})
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name));

const seedPackage = (packageDir: string, seed: readonly string[]): void => {
  mkdirSync(packageDir, {recursive: true});

  for (const relative of seed) {
    mkdirSync(path.join(packageDir, relative), {recursive: true});
  }

  if (seed.includes('test/mocks')) {
    writeFileSync(
      path.join(packageDir, 'test/mocks/database.ts'),
      [
        'export const resetTestData = async (): Promise<void> => {',
        '  await Promise.all([]);',
        '};',
        '',
        'export default {} as Record<string, never>;',
        '',
      ].join('\n')
    );
  }
};

describe.each(SCAFFOLDERS)('gaia scaffold $name package root', (scaffolder) => {
  let root: string;
  let stderrWrites: string[];

  beforeEach(() => {
    // `git` reports the physical path, and os.tmpdir() is a symlink on macOS.
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-package-root-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    stderrWrites = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderrWrites.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test.each([
    ['the repo root', ''],
    ['inside frontend/', 'frontend'],
  ])(
    'built-in default writes under frontend/ when run from %s',
    (_label, cwdRelative) => {
      const packageDir = path.join(root, 'frontend');
      seedPackage(packageDir, scaffolder.seed);
      const cwd = path.join(root, cwdRelative);

      expect(scaffolder.run(cwd)).toBe(EXIT_CODES.OK);

      for (const relative of scaffolder.expected) {
        expect(existsSync(path.join(packageDir, relative))).toBe(true);
      }
      // The failing state of the old code: a root-relative write.
      expect(existsSync(path.join(root, 'app'))).toBe(false);
      expect(existsSync(path.join(root, 'test'))).toBe(false);
    }
  );

  test('a path-"." registry keeps the app at the repo root', () => {
    writeFrontendRegistry(root, '.');
    seedPackage(root, scaffolder.seed);

    expect(scaffolder.run(root)).toBe(EXIT_CODES.OK);

    for (const relative of scaffolder.expected) {
      expect(existsSync(path.join(root, relative))).toBe(true);
    }
    expect(existsSync(path.join(root, 'frontend'))).toBe(false);
  });

  test('a malformed registry refuses with the gaia-packages message and writes nothing', () => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(path.join(root, '.gaia/packages.json'), '{not json');
    const before = listFiles(root).filter((file) => !file.includes('.git/'));

    expect(scaffolder.run(root)).not.toBe(EXIT_CODES.OK);

    expect(stderrWrites.join('')).toContain('gaia-packages:');
    expect(listFiles(root).filter((file) => !file.includes('.git/'))).toEqual(
      before
    );
    expect(existsSync(path.join(root, 'app'))).toBe(false);
    expect(existsSync(path.join(root, 'frontend'))).toBe(false);
  });
});

describe('gaia scaffold component --parent normalization', () => {
  let root: string;

  beforeEach(() => {
    root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-parent-')));
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    mkdirSync(path.join(root, 'frontend/app/components/Form'), {
      recursive: true,
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test.each(['app/components/Form', 'frontend/app/components/Form'])(
    'resolves --parent %s against the package and titles the story package-relative',
    (parent) => {
      expect(runComponent(['Field', '--parent', parent], {cwd: root})).toBe(
        EXIT_CODES.OK
      );

      const story = readFileSync(
        path.join(
          root,
          'frontend/app/components/Form/Field/tests/index.stories.tsx'
        ),
        'utf8'
      );

      expect(story).toContain('Components/Form/Field');
      expect(existsSync(path.join(root, 'frontend/frontend'))).toBe(false);
    }
  );
});
