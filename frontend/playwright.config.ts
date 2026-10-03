import {defineConfig, devices} from '@playwright/test';
import {config} from 'dotenv';

config();

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
    baseURL: 'http://localhost:5173',

    trace: 'retain-on-failure',
  },

  webServer: {
    command: 'pnpm dev',
    reuseExistingServer: !process.env.CI,
    timeout: 15_000,
    url: 'http://localhost:5173',
  },

  workers: process.env.CI ? 1 : undefined,
});
