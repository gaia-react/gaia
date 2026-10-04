import type {Page, TestInfo} from '@playwright/test';
import fs from 'node:fs';
import {expectNoSeriousA11yViolations} from '../a11y';
import {expect, test} from '../fixtures';
import type {StoryEntry} from '../storybook';
import {
  countStoriesInSource,
  loadStory,
  readStoryIndex,
  waitForRender,
} from '../storybook';
import {
  contrastRatio,
  expectTheme,
  MINIMUM_NON_TEXT_CONTRAST,
  resolveColors,
} from '../theme';

const THEMES = ['light', 'dark'] as const;
const NOTIFY_TYPES = [
  {id: 'utils-notify--error-toast', type: 'error'},
  {id: 'utils-notify--info', type: 'info'},
  {id: 'utils-notify--success', type: 'success'},
  {id: 'utils-notify--warning', type: 'warning'},
] as const;
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

// Collects page and console errors from the moment it is called.
const collectProblems = (page: Page): string[] => {
  const problems: string[] = [];

  page.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
  page.on('console', (message) => {
    if (message.type() === 'error') {
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

const saveScreenshot = async (page: Page, testInfo: TestInfo, name: string) => {
  await page.screenshot({path: testInfo.outputPath(`${name}.png`)});
};

test.describe('storybook a11y', () => {
  test('the built Storybook indexes exactly the stories in source', () => {
    requireIndex();
    const fromSource = countStoriesInSource();

    expect(fromSource, 'story exports found in source').toBeGreaterThan(0);
    expect(
      stories,
      `index.json lists ${stories.length} stories but source exports ${fromSource}: rebuild with \`pnpm build-storybook\``
    ).toHaveLength(fromSource);
  });

  for (const story of stories) {
    for (const theme of THEMES) {
      test(`${story.id} has no serious a11y violations in ${theme} mode`, async ({
        page,
      }, testInfo) => {
        const problems = collectProblems(page);

        await loadStory(page, story.id, theme);
        const phase = await waitForRender(page);

        expect(phase, 'story render phase').toBe('finished');
        expect(problems, 'errors while the story rendered').toEqual([]);
        await expect(page.locator('body')).not.toHaveClass(
          /sb-show-errordisplay/
        );
        await expect(page.locator('.sb-errordisplay')).toBeHidden();
        await expectStoryHasContent(page, story.id);
        // The Chromatic dual render wraps every story in a light and a dark
        // pane, which would scan one story under both themes at once.
        await expect(page.locator('#storybook-root .dark')).toHaveCount(0);
        await expectTheme(page, theme);
        await saveScreenshot(page, testInfo, `${story.id}-${theme}`);
        await expectNoSeriousA11yViolations(page, testInfo, {label: theme});
      });
    }
  }

  // At least one scanned story holds a link inside running text, and its
  // underline (not color alone) is what sets it apart.
  test('inline text links are underlined', async ({page}) => {
    requireIndex();
    await loadStory(page, 'styles-inline-link--default', 'light');
    await waitForRender(page);
    const links = page.locator('#storybook-root p a');

    await expect(links).not.toHaveCount(0);

    for (const link of await links.all()) {
      await expect(link).toHaveCSS('text-decoration-line', 'underline');
    }
  });

  for (const {id, type} of NOTIFY_TYPES) {
    for (const theme of THEMES) {
      test(`${type} toast icon has 3:1 contrast against its surface in ${theme} mode`, async ({
        page,
      }, testInfo) => {
        requireIndex();
        await loadStory(page, id, theme);
        await waitForRender(page);
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
        const iconRatio = contrastRatio(icon, surface);

        fs.writeFileSync(
          testInfo.outputPath('measurement.json'),
          JSON.stringify({iconRatio, kind: 'toast-contrast', theme, type})
        );
        expect(iconRatio).toBeGreaterThanOrEqual(MINIMUM_NON_TEXT_CONTRAST);
      });
    }
  }
});
