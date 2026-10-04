import type {BrowserContext, Page} from '@playwright/test';
import {expect} from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export type Rgba = {a: number; b: number; g: number; r: number};

export type Theme = 'dark' | 'light';

/** WCAG 1.4.11 minimum contrast for focus indicators and meaningful icons. */
export const MINIMUM_NON_TEXT_CONTRAST = 3;

const themeCss = fs.readFileSync(
  path.resolve(
    fileURLToPath(new URL('..', import.meta.url)),
    'app/styles/theme.css'
  ),
  'utf8'
);

/** The `--background` value the `.dark` block of the token file declares. */
export const readDarkBackground = (): string => {
  const darkStart = themeCss.indexOf('.dark {');
  const darkBlock = themeCss.slice(darkStart, themeCss.indexOf('}', darkStart));
  const tokenStart = darkBlock.indexOf('--background:');

  if (darkStart === -1 || tokenStart === -1) {
    throw new Error('theme.css has no `.dark { --background: ... }` token');
  }

  return darkBlock
    .slice(
      tokenStart + '--background:'.length,
      darkBlock.indexOf(';', tokenStart)
    )
    .trim();
};

/**
 * Resolves CSS color strings to sRGB bytes by painting each onto a 1x1 canvas,
 * since Chromium reports oklch and color-mix values unconverted. A translucent
 * color is painted over `backdrop` (opaque white by default) so the result is
 * what the user sees.
 */
export const resolveColors = async (
  page: Page,
  colors: {backdrop?: string; css: string}[]
): Promise<Rgba[]> =>
  page.evaluate((requests) => {
    const canvas = document.createElement('canvas');
    canvas.width = 1;
    canvas.height = 1;
    const context = canvas.getContext('2d', {willReadFrequently: true});
    if (!context) throw new Error('no 2d canvas context');

    return requests.map(({backdrop, css}) => {
      context.clearRect(0, 0, 1, 1);
      context.fillStyle = backdrop ?? '#ffffff';
      context.fillRect(0, 0, 1, 1);
      const probe = new Option().style;
      probe.color = css;
      if (probe.color === '') throw new Error(`unparseable color: ${css}`);
      context.fillStyle = css;
      context.fillRect(0, 0, 1, 1);
      const [r, g, b, a] = context.getImageData(0, 0, 1, 1).data;

      return {a: a / 255, b, g, r};
    });
  }, colors);

const channel = (value: number): number => {
  const scaled = value / 255;

  return scaled <= 0.03928 ? scaled / 12.92 : ((scaled + 0.055) / 1.055) ** 2.4;
};

const luminance = ({b, g, r}: Rgba): number =>
  0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);

/** WCAG 2.x contrast ratio between two opaque colors. */
export const contrastRatio = (first: Rgba, second: Rgba): number => {
  const lighter = Math.max(luminance(first), luminance(second));
  const darker = Math.min(luminance(first), luminance(second));

  return (lighter + 0.05) / (darker + 0.05);
};

/**
 * Fails unless the page is really in dark mode: `html` carries `dark` and the
 * body paints the `.dark` `--background` the token file declares. Both sides
 * resolve to sRGB the same way, so a dark scan that silently ran in light
 * (class dropped, token missing) fails here, before axe.
 */
export const expectDarkTheme = async (page: Page): Promise<void> => {
  await expect(page.locator('html')).toHaveClass(/(^|\s)dark(\s|$)/);
  const bodyBackground = await page.evaluate(
    () => getComputedStyle(document.body).backgroundColor
  );
  const [actual, expected] = await resolveColors(page, [
    {css: bodyBackground},
    {css: readDarkBackground()},
  ]);

  expect(actual, 'body background must equal the .dark --background').toEqual(
    expected
  );
};

/**
 * Puts the page in dark mode before any page script runs: the media query
 * reports dark (components that follow the system theme read it, not the
 * class), and `dark` is added to `html`. The init script fires while the
 * document is still empty, so it also watches for `html` to appear.
 */
export const forceDarkBeforeLoad = async (page: Page): Promise<void> => {
  await page.emulateMedia({colorScheme: 'dark'});
  await page.addInitScript(() => {
    const apply = () => {
      // The document has no root element yet when the init script first runs.
      // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
      document.documentElement?.classList.add('dark');
    };
    apply();
    new MutationObserver(apply).observe(document, {childList: true});
  });
};

/** Gets a page with no theme toggle into `theme` the way a returning visitor does: the theme cookie. */
export const enterThemeByCookie = async ({
  baseURL,
  context,
  theme,
}: {
  baseURL: string | undefined;
  context: BrowserContext;
  theme: Theme;
}): Promise<void> => {
  if (theme === 'dark') {
    await context.addCookies([{name: '__theme', url: baseURL, value: theme}]);
  }
};

/** Asserts the page is in `theme`: the dark assertion, or no `dark` class. */
export const expectTheme = async (page: Page, theme: Theme): Promise<void> => {
  if (theme === 'dark') {
    await expectDarkTheme(page);

    return;
  }
  await expect(page.locator('html')).not.toHaveClass(/(^|\s)dark(\s|$)/);
};
