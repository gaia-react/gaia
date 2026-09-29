import {afterEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, realpathSync, writeFileSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';

type GlobalWithAppDirectory = {__reactRouterAppDirectory?: string};

// eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
const originalAppDirectory = (globalThis as GlobalWithAppDirectory)
  .__reactRouterAppDirectory;

const makeTemporaryAppDirectory = () =>
  realpathSync(mkdtempSync(path.join(os.tmpdir(), 'spec-085-')));

afterEach(() => {
  // eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
  (globalThis as GlobalWithAppDirectory).__reactRouterAppDirectory =
    originalAppDirectory;
  vi.resetModules();
});

describe('leftover "+" route folder guard', () => {
  test('throws naming the offending folder when a "+" folder remains', async () => {
    const appDirectory = makeTemporaryAppDirectory();

    writeFileSync(
      path.join(appDirectory, 'root.tsx'),
      'export default function Root() { return null; }\n'
    );
    mkdirSync(path.join(appDirectory, 'routes', '_legacy+'), {recursive: true});
    writeFileSync(
      path.join(appDirectory, 'routes', '_legacy+', 'page.tsx'),
      'export default function Page() { return null; }\n'
    );

    // eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
    (globalThis as GlobalWithAppDirectory).__reactRouterAppDirectory =
      appDirectory;
    vi.resetModules();

    await expect(import('~/routes')).rejects.toThrow(/_legacy\+/);
  });

  test('discovers a flat dot-delimited file when no "+" folder remains', async () => {
    const appDirectory = makeTemporaryAppDirectory();

    writeFileSync(
      path.join(appDirectory, 'root.tsx'),
      'export default function Root() { return null; }\n'
    );
    mkdirSync(path.join(appDirectory, 'routes'), {recursive: true});
    writeFileSync(
      path.join(appDirectory, 'routes', '_legacy.page.tsx'),
      'export default function Page() { return null; }\n'
    );

    // eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
    (globalThis as GlobalWithAppDirectory).__reactRouterAppDirectory =
      appDirectory;
    vi.resetModules();

    const routesModule = await import('~/routes');

    await expect(routesModule.default).resolves.toEqual(
      expect.arrayContaining([
        expect.objectContaining({id: 'routes/_legacy.page'}),
      ])
    );
  });
});
