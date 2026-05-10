import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

// See home-a11y.spec.ts — same brand exemption (the CTA renders in
// brand orange below WCAG 2 AA contrast).
const BRAND_CTA_EXEMPTION = 'a[href="https://github.com/gaia-react/gaia"]';

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
  await page.locator('select[name="language"]').selectOption('en');
  await hydration(page);

  await expectNoSeriousA11yViolations(page, testInfo, builder);
});
