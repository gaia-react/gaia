import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import {enterThemeByCookie, expectTheme} from '../theme';
import {hydration} from '../utils';

const LEGAL_ROUTES = [
  {heading: 'Privacy Policy', path: '/privacy'},
  {heading: 'Terms of Service', path: '/terms'},
] as const;

const THEMES = ['light', 'dark'] as const;

for (const {heading, path} of LEGAL_ROUTES) {
  for (const theme of THEMES) {
    test(`${path} renders and has no serious a11y violations in ${theme} mode`, async ({
      baseURL,
      context,
      page,
    }, testInfo) => {
      // The legal pages have no theme toggle, so dark mode arrives the way a
      // returning visitor's does: through the theme cookie.
      await enterThemeByCookie({baseURL, context, theme});

      await page.goto(path);
      await hydration(page);

      // The page renders its heading without error.
      await expect(
        page.getByRole('heading', {level: 1, name: heading})
      ).toBeVisible();

      // The simplified Layout provides no controls on legal pages.
      await expect(
        page.getByRole('button', {
          name: /enable (dark|light) mode|use system theme/i,
        })
      ).toHaveCount(0);
      await expect(page.locator('select[name="language"]')).toHaveCount(0);

      await expectTheme(page, theme);

      await expectNoSeriousA11yViolations(page, testInfo, {label: theme});
    });
  }
}
