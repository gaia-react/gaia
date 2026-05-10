import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

test('home page has no serious a11y violations', async ({page}, testInfo) => {
  await page.goto('/');
  await hydration(page);
  await expectNoSeriousA11yViolations(page, testInfo);
});
