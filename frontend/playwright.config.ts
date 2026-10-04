import {defineConfig, devices} from '@playwright/test';
import {config} from 'dotenv';
import {fileURLToPath} from 'node:url';
import {requireDevPorts, resolveSiteUrl} from './dev-ports';
import {decideServerReuse} from './dev-ports-reuse';

// Captured before dotenv loads the .env (symlinked from main in a worktree),
// whose SITE_URL carries main's port and would otherwise reach the spawned server.
const exportedSiteUrl = process.env.SITE_URL;

config();

const packageDirectory = fileURLToPath(new URL('.', import.meta.url));
// Throws in a linked worktree with no port file, so no spec runs on main's ports.
const ports = requireDevPorts(packageDirectory);
const siteUrl = resolveSiteUrl({exportedSiteUrl, ports});

if (ports.source === 'port-file' && siteUrl !== undefined) {
  process.env.SITE_URL = siteUrl;
}

const devUrl = `http://localhost:${ports.devPort}`;

/**
 * You can change this to "true" this to test in multiple browsers if you prefer.
 * Testing multiple browsers can significantly increase test time on CI.
 * Recommend only testing multiple browsers locally.
 */
const TEST_ALL_BROWSERS = false;

const otherBrowsers =
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
  !process.env.CI && TEST_ALL_BROWSERS ?
    [
      {
        name: 'webkit',
        use: {...devices['Desktop Safari']},
      },
      {
        name: 'mozilla',
        use: {...devices['Desktop Firefox']},
      },
      {
        name: 'Mobile Chrome',
        use: {...devices['Pixel 7']},
      },
      {
        name: 'Mobile Safari',
        use: {...devices['iPhone 15']},
      },
    ]
  : [];

export default defineConfig({
  expect: {
    timeout: 10_000,
  },
  forbidOnly: !!process.env.CI,

  fullyParallel: true,

  // Serial `/` warm-up after the dev server boots, so the first parallel spec
  // does not race Vite's cold dep-optimize. See ./.playwright/global-setup.ts.
  globalSetup: './.playwright/global-setup.ts',

  // the .gitignore file is configured to ignore this directory
  // if you change this, change it in .gitignore, as well
  outputDir: './.playwright/output',

  projects: [
    {
      name: 'chromium',
      use: {...devices['Desktop Chrome']},
    },
    ...otherBrowsers,
  ],

  reporter: 'list',

  // No local retries: the global-setup warm-up and the hydration helper's
  // probe-then-reload self-heal the cold dep-optimize race (the first `pnpm pw`
  // after a dep or Vite-config change boots a cold cache and the first request
  // can lose the race to Vite's optimizer, failing the dynamic import of
  // entry.client.tsx so the page never hydrates), so a real flake fails instead
  // of being masked. CI keeps retries as general flake insurance.
  retries: process.env.CI ? 2 : 0,
  testDir: './.playwright/e2e',
  testMatch: '**/*.spec.ts',

  use: {
    baseURL: devUrl,

    trace: 'retain-on-failure',
  },

  webServer: [
    {
      command: 'pnpm dev',
      reuseExistingServer: decideServerReuse({
        isContinuousIntegration: !!process.env.CI,
        port: ports.devPort,
        treeRoot: ports.treeRoot,
      }),
      timeout: 15_000,
      url: devUrl,
    },
    // Serves the built Storybook for the story a11y scan. `pnpm pw` does not
    // build it: run `pnpm build-storybook` first (CI does). The server starts
    // without a build so the other specs run; the story spec fails, never
    // skips, naming the build command.
    {
      command: `pnpm exec tsx .playwright/storybook-server.ts ${ports.storybookPort}`,
      reuseExistingServer: decideServerReuse({
        isContinuousIntegration: !!process.env.CI,
        port: ports.storybookPort,
        treeRoot: ports.treeRoot,
      }),
      timeout: 15_000,
      url: `http://127.0.0.1:${ports.storybookPort}/__ready`,
    },
  ],

  workers: process.env.CI ? 1 : undefined,
});
