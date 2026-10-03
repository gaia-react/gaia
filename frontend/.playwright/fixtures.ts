import AxeBuilder from '@axe-core/playwright';
import {test as base, expect} from '@playwright/test';

type AxeFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

/**
 * Extended Playwright test with an axe-core builder fixture.
 * Default tag set: WCAG 2.0/2.1 A and AA.
 */
export const test = base.extend<AxeFixtures>({
  makeAxeBuilder: async ({page}, use) => {
    const make = () =>
      new AxeBuilder({page}).withTags([
        'wcag2a',
        'wcag2aa',
        'wcag21a',
        'wcag21aa',
      ]);

    // `use` is the Playwright fixture-API callback parameter, not a React hook.
    // eslint-disable-next-line react-hooks/rules-of-hooks
    await use(make);
  },
});

export {expect};
