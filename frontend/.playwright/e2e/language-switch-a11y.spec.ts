import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

test('language switcher has no serious a11y violations', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  // playwright.config.ts runs this spec only when LANGUAGES has two or more
  // entries, the condition under which the switcher renders.
  const switcher = page.locator('select[name="language"]');

  // Smoke-test the switcher in its initial state.
  await expectNoSeriousA11yViolations(page, testInfo, {label: 'initial'});

  // Re-select the current language to exercise the switch flow.
  await switcher.selectOption('en');
  await hydration(page);

  await expectNoSeriousA11yViolations(page, testInfo, {label: 'after-switch'});
});
