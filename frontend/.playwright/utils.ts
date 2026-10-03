import type {Locator, Page} from '@playwright/test';
import {expect} from '@playwright/test';

export const metatag = (page: Page, name: string): Locator =>
  page.locator(`head > meta[name="${name}"]`);

// Resolves true when the barrier had to self-heal with a reload, so a caller
// asserting on console or page errors can tell a clean load from a recovered
// one: the reload's aborted requests report errors that say nothing about the
// app, and listeners registered on the Page survive it.
export const hydration = async (page: Page): Promise<boolean> => {
  const meta = metatag(page, 'hydrated');

  // Warm server: the page hydrates within the probe window and the meta tag
  // attaches. Cold dev server: the first hit of a route makes Vite re-optimize
  // dependencies mid-flight, which fails the dynamic import of entry.client.tsx
  // so the page never hydrates and the meta never appears.
  const isHydrated = await meta
    .waitFor({state: 'attached', timeout: 5000})
    .then(() => true)
    .catch(() => false);

  // On a cold miss, reload once onto the now-optimized bundle and wait with a
  // generous window. Route-agnostic and idle on a warm server, which hydrates
  // within the probe and skips the reload.
  if (!isHydrated) {
    await page.reload();
  }

  await expect(meta).toHaveAttribute('content', 'true', {timeout: 30_000});

  return !isHydrated;
};
