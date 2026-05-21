import AxeBuilder from '@axe-core/playwright';
import type {Page, TestInfo} from '@playwright/test';

const SEVERITY_FAIL = new Set(['critical', 'serious']);

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
