import type {Page, TestInfo} from '@playwright/test';
import fs from 'node:fs';
import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import type {StoryEntry} from '../storybook';
import {
  getStoryIdentity,
  listStoryIdentitiesInSource,
  loadStory,
  readStoryIndex,
  waitForRender,
} from '../storybook';
import {
  computeContrastRatio,
  expectTheme,
  MINIMUM_NON_TEXT_CONTRAST,
  resolveColors,
} from '../theme';
import type {Theme} from '../theme';

const NOTIFY_TYPES = [
  {id: 'utils-notify--error-toast', type: 'error'},
  {id: 'utils-notify--info', type: 'info'},
  {id: 'utils-notify--success', type: 'success'},
  {id: 'utils-notify--warning', type: 'warning'},
] as const;
type NotifyType = (typeof NOTIFY_TYPES)[number]['type'];
const TOAST_STORY_IDS = new Set<string>([
  ...NOTIFY_TYPES.map(({id}) => id),
  'components-ui-toast--default',
  'components-ui-toast--error-type',
  'components-ui-toast--info',
  'components-ui-toast--loading',
  'components-ui-toast--success',
  'components-ui-toast--warning',
  'components-ui-toast--with-action',
  'utils-notify--with-stack',
]);
// Stories whose subject renders nothing in this project: the language select
// hides itself in a single-language project.
const RENDERS_NOTHING_BY_DESIGN = new Set([
  'components-languageselect--default',
]);

// A missing build is a failing test, never a skipped or empty one.
let stories: StoryEntry[] = [];
let indexError: Error | undefined;

try {
  stories = readStoryIndex();
} catch (error) {
  indexError = error as Error;
}

const requireIndex = () => {
  if (indexError) throw indexError;
};

// React Router's createRoutesStub writes this placeholder into its manifest,
// so `<Scripts/>` in a stubbed story modulepreloads a file no build serves.
// Once the MSW service worker is in the request path, Chromium logs that 404
// as a console error.
const ROUTES_STUB_MODULE_PATH = '/build/stub-path-to-module.js';

// Collects page and console errors from the moment it is called.
const collectProblems = (page: Page): string[] => {
  const problems: string[] = [];

  page.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
  page.on('console', (message) => {
    if (
      message.type() === 'error' &&
      !message.location().url.endsWith(ROUTES_STUB_MODULE_PATH)
    ) {
      problems.push(
        `console error: ${message.text()} (${message.location().url})`
      );
    }
  });

  return problems;
};

const expectStoryHasContent = async (page: Page, storyId: string) => {
  const isExempt =
    TOAST_STORY_IDS.has(storyId) || RENDERS_NOTHING_BY_DESIGN.has(storyId);
  // A layout wrapper alone does not count: a story that renders nothing would
  // scan as an empty, passing page, so the root needs text or a control, icon,
  // image or landmark. Toast stories render into a portal and are held to the
  // visible-toast check instead.
  const hasContent =
    isExempt ||
    (await page
      .locator('#storybook-root')
      .evaluate(
        (root) =>
          root.textContent.trim() !== '' ||
          root.querySelector(
            'svg, img, input, select, textarea, button, canvas, video, hr, [role]'
          ) !== null
      ));

  expect(hasContent, 'story rendered no content into #storybook-root').toBe(
    true
  );

  if (TOAST_STORY_IDS.has(storyId)) {
    await expect(page.locator('[data-slot="toast"]').first()).toBeVisible();
  }
};

const expectToastIconContrast = async (
  page: Page,
  testInfo: TestInfo,
  {theme, type}: {theme: Theme; type: NotifyType}
) => {
  const toast = page.locator(`[data-slot="toast"][data-type="${type}"]`);

  await expect(toast).toBeVisible();
  const iconLocator = toast.locator('[data-slot="toast-icon"] svg');

  await expect(iconLocator).toBeVisible();
  const colors = {
    icon: await iconLocator.evaluate(
      (element) => getComputedStyle(element).color
    ),
    page: await page.evaluate(
      () => getComputedStyle(document.body).backgroundColor
    ),
    surface: await toast.evaluate(
      (element) => getComputedStyle(element).backgroundColor
    ),
  };
  const [surface] = await resolveColors(page, [
    {backdrop: colors.page, css: colors.surface},
  ]);
  const [icon] = await resolveColors(page, [
    {backdrop: colors.surface, css: colors.icon},
  ]);
  const iconRatio = computeContrastRatio(icon, surface);

  fs.writeFileSync(
    testInfo.outputPath('measurement.json'),
    JSON.stringify({iconRatio, kind: 'toast-contrast', theme, type})
  );
  expect(
    iconRatio,
    `${type} toast icon contrast against its surface in ${theme} mode`
  ).toBeGreaterThanOrEqual(MINIMUM_NON_TEXT_CONTRAST);
};

test.describe('storybook a11y', () => {
  test('the built Storybook indexes exactly the stories in source', () => {
    requireIndex();
    const fromSource = listStoryIdentitiesInSource();
    const fromIndex = new Set(stories.map(getStoryIdentity));
    const missingFromBuild = [...fromSource].filter(
      (identity) => !fromIndex.has(identity)
    );
    const missingFromSource = [...fromIndex].filter(
      (identity) => !fromSource.has(identity)
    );

    expect(fromSource.size, 'story exports found in source').toBeGreaterThan(0);
    expect(
      {missingFromBuild, missingFromSource},
      'index.json and source list different stories: rebuild with `pnpm build-storybook`'
    ).toEqual({missingFromBuild: [], missingFromSource: []});
  });

  // Dark only: the Vitest storybook project already runs every story under
  // addon-a11y in the light theme, failing on any impact rather than only
  // critical and serious, so a light pass here would repeat a weaker check.
  const storyScanTheme = 'dark';

  for (const story of stories) {
    // The scan already has a notify story loaded in dark, so its dark icon
    // contrast is measured here rather than by a second load below.
    const notifyTypes = NOTIFY_TYPES.filter(({id}) => id === story.id);

    test(`${story.id} has no serious a11y violations in ${storyScanTheme} mode`, async ({
      page,
    }, testInfo) => {
      const problems = collectProblems(page);

      await loadStory(page, story.id, storyScanTheme);
      const phase = await waitForRender(page);

      expect(phase, 'story render phase').toBe('finished');
      expect(problems, 'errors while the story rendered').toEqual([]);
      await expect(page.locator('body')).not.toHaveClass(
        /sb-show-errordisplay/
      );
      await expect(page.locator('.sb-errordisplay')).toBeHidden();
      await expectStoryHasContent(page, story.id);
      await expectTheme(page, storyScanTheme);

      // Before the axe scan: a notify toast dismisses after 5s.
      for (const {type} of notifyTypes) {
        await expectToastIconContrast(page, testInfo, {
          theme: storyScanTheme,
          type,
        });
      }

      await expectNoSeriousA11yViolations(page, testInfo, {
        label: storyScanTheme,
      });
    });
  }

  // At least one scanned story holds a link inside running text, and its
  // underline (not color alone) is what sets it apart.
  test('inline text links are underlined', async ({page}) => {
    requireIndex();
    await loadStory(page, 'styles-inlinelink--default', 'light');
    await waitForRender(page);
    const links = page.locator('#storybook-root p a');

    await expect(links).not.toHaveCount(0);

    for (const link of await links.all()) {
      await expect(link).toHaveCSS('text-decoration-line', 'underline');
    }
  });

  // Light only: the dark measurement runs inside the dark story scan above.
  for (const {id, type} of NOTIFY_TYPES) {
    test(`${type} toast icon has 3:1 contrast against its surface in light mode`, async ({
      page,
    }, testInfo) => {
      requireIndex();
      await loadStory(page, id, 'light');
      await waitForRender(page);
      await expectToastIconContrast(page, testInfo, {theme: 'light', type});
    });
  }
});
