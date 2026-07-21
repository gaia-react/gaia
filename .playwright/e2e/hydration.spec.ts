import {expect, test} from '../fixtures';
import {hydration} from '../utils';

// React reports every server/client divergence through console.error, and each
// of those messages names hydration.
const HYDRATION_MISMATCH = /hydrat(?:ed|ion)/i;

test('home page hydrates with no server/client mismatch', async ({page}) => {
  const mismatches: string[] = [];

  page.on('console', (message) => {
    if (message.type() === 'error' && HYDRATION_MISMATCH.test(message.text())) {
      mismatches.push(message.text());
    }
  });

  await page.goto('/');
  await hydration(page);

  expect(mismatches).toEqual([]);
});
