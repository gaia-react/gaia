import {BRAND_CTA_EXEMPTION, expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

test('language switcher has no serious a11y violations', async ({
  page,
  makeAxeBuilder,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  const builder = makeAxeBuilder().exclude(BRAND_CTA_EXEMPTION);

  // Smoke-test the switcher in its initial state.
  await expectNoSeriousA11yViolations(page, testInfo, builder);

  // Re-select the current language to exercise the switch flow.
  await page.getByRole('combobox', {name: 'Language'}).selectOption('en');
  await hydration(page);

  await expectNoSeriousA11yViolations(page, testInfo, builder);
});
