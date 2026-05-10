import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

test('language switcher has no serious a11y violations', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  // Smoke-test the switcher in its initial state.
  await expectNoSeriousA11yViolations(page, testInfo);

  // Re-select the current language to exercise the switch flow.
  await page.locator('select[name="language"]').selectOption('en');
  await hydration(page);

  await expectNoSeriousA11yViolations(page, testInfo);
});
