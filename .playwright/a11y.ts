import AxeBuilder from '@axe-core/playwright';
import type {Page, TestInfo} from '@playwright/test';

const SEVERITY_FAIL = new Set(['critical', 'serious']);

/**
 * Selector for the home CTA. The link renders in the brand orange
 * (`text-claude-500`, `--color-claude-500: #d97757`) which has a 3.12:1
 * contrast ratio against white — below WCAG 2 AA's 4.5:1 for normal
 * text. Documented brand exemption: any spec scanning `/` should
 * `.exclude(BRAND_CTA_EXEMPTION)` so every other element keeps full
 * contrast coverage without surfacing the brand decision as a failure.
 */
export const BRAND_CTA_EXEMPTION =
  'a[href="https://github.com/gaia-react/gaia"]';

/**
 * Scans the current page with axe and asserts no critical/serious
 * violations. Moderate/minor violations are attached to the test info
 * and surfaced via console.warn.
 */
export const expectNoSeriousA11yViolations = async (
  page: Page,
  testInfo: TestInfo,
  builder?: AxeBuilder
): Promise<void> => {
  const axe =
    builder ??
    new AxeBuilder({page}).withTags([
      'wcag2a',
      'wcag2aa',
      'wcag21a',
      'wcag21aa',
      'wcag22a',
      'wcag22aa',
    ]);

  const {violations} = await axe.analyze();
  const blocking = violations.filter((v) =>
    SEVERITY_FAIL.has(v.impact ?? 'minor')
  );
  const advisory = violations.filter(
    (v) => !SEVERITY_FAIL.has(v.impact ?? 'minor')
  );

  if (advisory.length > 0) {
    await testInfo.attach('axe-advisory.json', {
      body: JSON.stringify(advisory, null, 2),
      contentType: 'application/json',
    });

    for (const v of advisory) {
      // eslint-disable-next-line no-console -- advisory surface for moderate/minor violations
      console.warn(`a11y advisory (${v.impact}) ${v.id}: ${v.help}`);
    }
  }

  if (blocking.length > 0) {
    await testInfo.attach('axe-violations.json', {
      body: JSON.stringify(blocking, null, 2),
      contentType: 'application/json',
    });

    throw new Error(
      `Found ${blocking.length} blocking a11y violations: ${blocking
        .map((v) => `${v.id} (${v.impact})`)
        .join(', ')}`
    );
  }
};
