import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

// eslint-disable-next-line playwright/expect-expect -- expectNoSeriousA11yViolations is the assertion
test('home page has no serious a11y violations', async ({page}, testInfo) => {
  await page.goto('/');
  await hydration(page);
  await expectNoSeriousA11yViolations(page, testInfo);
});

test('home dark mode has no serious a11y violations', async ({
  page,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  const toggle = page.getByRole('button', {
    name: /enable (dark|light) mode|use system theme/i,
  });
  await expect(toggle).toBeVisible();

  // From default system state, dark requires two clicks (system -> light -> dark).
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-label', 'Enable dark mode');

  await toggle.click();
  await expect(page.locator('html')).toHaveClass(/dark/);

  // The toggle stays labeled and keyboard-operable in dark mode.
  await expect(toggle).toHaveAttribute('aria-label', 'Use system theme');
  await toggle.focus();
  await expect(toggle).toBeFocused();

  await expectNoSeriousA11yViolations(page, testInfo, {label: 'dark'});
});

test('home page landmarks and headings pass best-practice rules', async ({
  page,
  makeAxeBuilder,
}, testInfo) => {
  await page.goto('/');
  await hydration(page);

  // Run axe with the best-practice tag to cover landmark and heading rules.
  const axe = makeAxeBuilder().withTags(['best-practice']);
  const {violations} = await axe.analyze();

  const targetRules = new Set([
    'region',
    'landmark-one-main',
    'heading-order',
    'page-has-heading-one',
  ]);
  const relevant = violations.filter((v) => targetRules.has(v.id));

  if (relevant.length > 0) {
    await testInfo.attach('axe-landmark-violations.json', {
      body: JSON.stringify(relevant, null, 2),
      contentType: 'application/json',
    });
    throw new Error(
      `Found ${relevant.length} landmark/heading violations: ${relevant
        .map((v) => `${v.id} (${v.impact})`)
        .join(', ')}`
    );
  }

  // Structural invariants: exactly one <main> (Layout-owned) and one <h1>.
  await expect(page.locator('main')).toHaveCount(1);
  await expect(page.locator('h1')).toHaveCount(1);
});
