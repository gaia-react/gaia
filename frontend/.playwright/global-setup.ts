import type {FullConfig} from '@playwright/test';
import {chromium} from '@playwright/test';
import {hydration} from './utils';

/**
 * Warm up the dev server before the parallel specs run.
 *
 * The web server boots with a cold Vite dep-optimize cache. The first browser
 * hit of a route makes Vite optimize dependencies; when that happens mid-flight
 * it invalidates the in-flight client bundle and fails the dynamic import of
 * entry.client.tsx, so the page never hydrates. A single serial `/` navigation
 * here front-loads the initial optimize before the fully-parallel specs race
 * for it. Playwright starts the configured `webServer` before global setup, so
 * the server is up by the time this runs; on a warm server it returns quickly.
 */
const globalSetup = async (config: FullConfig): Promise<void> => {
  const baseURL = config.projects[0]?.use.baseURL ?? 'http://localhost:5173';
  const browser = await chromium.launch();

  try {
    const page = await browser.newPage();
    await page.goto(baseURL);
    await hydration(page);
  } finally {
    await browser.close();
  }
};

export default globalSetup;
