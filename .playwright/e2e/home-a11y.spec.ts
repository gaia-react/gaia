import {BRAND_CTA_EXEMPTION, expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

test('home page has no serious a11y violations', async ({
  page,
  makeAxeBuilder,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  const builder = makeAxeBuilder().exclude(BRAND_CTA_EXEMPTION);

  await expectNoSeriousA11yViolations(page, testInfo, builder);
});
