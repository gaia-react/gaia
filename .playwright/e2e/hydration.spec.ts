import {expect, test} from '@playwright/test';
import {hydration} from '../utils';

test('home page loads with no console or page errors', async ({page}) => {
  const errors: string[] = [];

  // React splits error reporting across two channels. Attribute mismatches are
  // a direct console.error, but a throw-path failure goes to
  // window.reportError, which Chromium delivers as pageerror and never as a
  // console message. Watch both, and treat any error during the load as the
  // failure it is.
  page.on('console', (message) => {
    if (message.type() === 'error') {
      errors.push(message.text());
    }
  });
  page.on('pageerror', (error) => {
    errors.push(error.message);
  });

  // The first load absorbs the cold dev-server race: hydration() self-heals it
  // with a reload, and the requests that lost the race report errors that say
  // nothing about the app. Listeners survive a reload, so reset and assert on a
  // second, known-warm load.
  await page.goto('/');
  await hydration(page);

  errors.length = 0;

  await page.reload();
  await hydration(page);

  expect(errors).toEqual([]);
});
