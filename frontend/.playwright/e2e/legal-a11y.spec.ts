import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

const LEGAL_ROUTES = [
  {h1: 'Privacy Policy', path: '/privacy'},
  {h1: 'Terms of Service', path: '/terms'},
] as const;

for (const {h1, path} of LEGAL_ROUTES) {
  test(`${path} renders and has no serious a11y violations`, async ({
    page,
  }, testInfo) => {
    await page.goto(path);
    await hydration(page);

    // The page renders its heading without error.
    await expect(page.getByRole('heading', {level: 1, name: h1})).toBeVisible();

    // The simplified Layout provides no controls on legal pages.
    await expect(
      page.getByRole('button', {
        name: /enable (dark|light) mode|use system theme/i,
      })
    ).toHaveCount(0);
    await expect(page.locator('select[name="language"]')).toHaveCount(0);

    await expectNoSeriousA11yViolations(page, testInfo);
  });
}
