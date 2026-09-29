import {afterEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, realpathSync, writeFileSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';

type GlobalWithAppDirectory = {__reactRouterAppDirectory?: string};

const appDirectoryGlobal = globalThis as GlobalWithAppDirectory;

// eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
const originalAppDirectory = appDirectoryGlobal.__reactRouterAppDirectory;

const setAppDirectory = (appDirectory: string | undefined) => {
  // eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
  appDirectoryGlobal.__reactRouterAppDirectory = appDirectory;
  vi.resetModules();
};

const writeTemporaryApp = (routeFile: string) => {
  const appDirectory = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), 'spec-085-'))
  );

  writeFileSync(
    path.join(appDirectory, 'root.tsx'),
    'export default function Root() { return null; }\n'
  );
  mkdirSync(path.dirname(path.join(appDirectory, 'routes', routeFile)), {
    recursive: true,
  });
  writeFileSync(
    path.join(appDirectory, 'routes', routeFile),
    'export default function Page() { return null; }\n'
  );
  setAppDirectory(appDirectory);
};

afterEach(() => {
  setAppDirectory(originalAppDirectory);
});

describe('leftover "+" route folder guard', () => {
  test('throws naming the offending folder when a "+" folder remains', async () => {
    writeTemporaryApp(path.join('_legacy+', 'page.tsx'));

    await expect(import('~/routes')).rejects.toThrow(/_legacy\+/);
  });

  test('discovers a flat dot-delimited file when no "+" folder remains', async () => {
    writeTemporaryApp('_legacy.page.tsx');

    const routesModule = await import('~/routes');

    await expect(routesModule.default).resolves.toEqual(
      expect.arrayContaining([
        expect.objectContaining({id: 'routes/_legacy.page'}),
      ])
    );
  });
});
