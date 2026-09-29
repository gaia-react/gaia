import {ACTION_PATHS} from '../../app/action-paths';
import {expect, test} from '../fixtures';
import {hydration} from '../utils';

const PAGES = ['/', '/privacy', '/terms'] as const;

for (const path of PAGES) {
  test(`${path} responds 200`, async ({page}) => {
    const response = await page.goto(path);
    expect(response?.status()).toBe(200);
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
