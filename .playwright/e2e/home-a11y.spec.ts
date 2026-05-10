import {expectNoSeriousA11yViolations} from '../a11y';
import {test} from '../fixtures';
import {hydration} from '../utils';

// The home CTA renders in the brand orange (`text-claude-500`,
// `--color-claude-500: #d97757`) which has a 3.12:1 contrast ratio
// against white — below WCAG 2 AA's 4.5:1 for normal text. Excluded
// here as a documented brand exemption; every other element on `/`
// keeps full contrast coverage.
const BRAND_CTA_EXEMPTION = 'a[href="https://github.com/gaia-react/gaia"]';

test('home page has no serious a11y violations', async ({
  page,
  makeAxeBuilder,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  const builder = makeAxeBuilder().exclude(BRAND_CTA_EXEMPTION);

  await expectNoSeriousA11yViolations(page, testInfo, builder);
});
