import {expect, test} from '@playwright/test';
import {hydration} from '../utils';

test('home page hydrates with no server/client mismatch', async ({page}) => {
  const errors: string[] = [];

  // React splits hydration reporting across two channels. Attribute diffs are a
  // direct console.error, but a throw-path failure goes to window.reportError,
  // which Chromium delivers as pageerror and never as a console message. Watch
  // both, and treat any error during the load as the failure it is.
  page.on('console', (message) => {
    if (message.type() === 'error') {
      errors.push(message.text());
    }
  });
  page.on('pageerror', (error) => {
    errors.push(error.message);
  });

  await page.goto('/');
  await hydration(page);

  expect(errors).toEqual([]);
});
