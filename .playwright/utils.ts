import type {Page} from '@playwright/test';
import {expect} from '@playwright/test';

export const metatag = (page: Page, name: string) =>
  page.locator(`head > meta[name="${name}"]`);

export const hydration = async (page: Page) => {
  const meta = metatag(page, 'hydrated');

  // Warm server: the page hydrates within the probe window and the meta tag
  // attaches. Cold dev server: the first hit of a route makes Vite re-optimize
  // dependencies mid-flight, which fails the dynamic import of entry.client.tsx
  // so the page never hydrates and the meta never appears.
  const hydrated = await meta
    .waitFor({state: 'attached', timeout: 5_000})
    .then(() => true)
    .catch(() => false);

  // On a cold miss, reload once onto the now-optimized bundle and wait with a
  // generous window. Route-agnostic and idle on a warm server, which hydrates
  // within the probe and skips the reload.
  if (!hydrated) {
    await page.reload();
  }

  await expect(meta).toHaveAttribute('content', 'true', {timeout: 30_000});
};
