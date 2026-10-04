import type {Page} from '@playwright/test';
import {ACTION_PATHS} from '../../app/action-paths';
import common from '../../app/languages/en/common';
import legal from '../../app/languages/en/pages/legal';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

type PageContent = {
  expectContent: (page: Page) => Promise<void>;
  path: string;
};

// Each check asserts content the page component itself owns, so a route that
// imports the wrong page fails here even when the status is still 200.
const PAGES: readonly PageContent[] = [
  {
    expectContent: async (page) => {
      await expect(
        page.getByRole('heading', {level: 1, name: common.meta.siteName})
      ).toBeVisible();
    },
    path: '/',
  },
  {
    expectContent: async (page) => {
      await expect(
        page.getByText(legal.privacy.paragraphs[0], {exact: true})
      ).toBeVisible();
    },
    path: '/privacy',
  },
  {
    expectContent: async (page) => {
      await expect(
        page.getByText(legal.terms.paragraphs[0], {exact: true})
      ).toBeVisible();
    },
    path: '/terms',
  },
];

for (const {expectContent, path} of PAGES) {
  test(`${path} responds 200 and renders its own page`, async ({page}) => {
    const response = await page.goto(path);
    expect(response?.status()).toBe(200);
    await expectContent(page);
  });
}

test('theme toggle POST resolves 2xx', async ({page}) => {
  await page.goto('/');
  await hydration(page);

  const toggle = page.getByRole('button', {
    name: /enable (dark|light) mode|use system theme/i,
  });
  await expect(toggle).toBeVisible();

  const [response] = await Promise.all([
    page.waitForResponse(
      (candidateResponse) =>
        candidateResponse.request().method() === 'POST' &&
        new URL(candidateResponse.url()).pathname.startsWith(
          ACTION_PATHS.themeSwitch
        )
    ),
    toggle.click(),
  ]);
  expect(response.status()).toBeGreaterThanOrEqual(200);
  expect(response.status()).toBeLessThan(300);
});

test('set-language action redirects and sets the language cookie', async ({
  request,
}) => {
  const response = await request.post(ACTION_PATHS.setLanguage, {
    form: {language: 'en', redirectUrl: '/'},
    maxRedirects: 0,
  });
  expect(response.status()).toBe(302);
  expect(response.headers().location).toBe('/');
  expect(response.headers()['set-cookie']).toMatch(/^lng=/);
});
