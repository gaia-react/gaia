import type {Locator, Page} from '@playwright/test';
import fs from 'node:fs';
import {expect, test} from '../fixtures';
import {loadStory, waitForRender} from '../storybook';
import type {Rgba} from '../theme';
import {
  contrastRatio,
  expectTheme,
  MINIMUM_NON_TEXT_CONTRAST,
  resolveColors,
} from '../theme';

const MAXIMUM_TABS = 12;
const SURFACES = ['background', 'card', 'input'] as const;

const CONTROLS = [
  {
    control: 'button',
    id: 'components-ui-button--default',
    locate: (page: Page) => page.getByRole('button').first(),
  },
  {
    control: 'input',
    id: 'components-ui-input--default',
    locate: (page: Page) => page.getByRole('textbox').first(),
  },
  {
    control: 'native-select',
    id: 'components-ui-nativeselect--default',
    locate: (page: Page) => page.getByRole('combobox').first(),
  },
  {
    control: 'checkbox',
    id: 'components-ui-checkbox--default',
    locate: (page: Page) => page.getByRole('checkbox').first(),
  },
  {
    control: 'radio-group',
    id: 'components-ui-radiogroup--default',
    locate: (page: Page) => page.getByRole('radio').first(),
  },
] as const;

type FocusStyles = {
  borderColor: string;
  boxShadow: string;
  outlineColor: string;
  outlineStyle: string;
  outlineWidth: string;
  tokens: Record<(typeof SURFACES)[number], string>;
};

// Splits a computed box-shadow list on its top-level commas.
const splitShadows = (value: string): string[] => {
  const layers: string[] = [];
  let depth = 0;
  let start = 0;

  for (let index = 0; index < value.length; index += 1) {
    const character = value.charAt(index);

    if (character === '(') depth += 1;
    if (character === ')') depth -= 1;

    if (character === ',' && depth === 0) {
      layers.push(value.slice(start, index).trim());
      start = index + 1;
    }
  }
  layers.push(value.slice(start).trim());

  return layers;
};

// The painted focus ring: the one outset, non-zero-spread layer of the
// computed box-shadow. Utilities that remove the ring leave only zero-size
// layers, which `box-shadow` still reports as something other than `none`.
const findRingColor = (boxShadow: string): string | undefined => {
  for (const layer of splitShadows(boxShadow)) {
    const open = layer.indexOf('(');
    const colorStart = layer.lastIndexOf(' ', open) + 1;
    const colorEnd = layer.indexOf(')', open) + 1;
    const lengths = (layer.slice(0, colorStart) + layer.slice(colorEnd))
      .split(' ')
      .filter((part) => part.endsWith('px'))
      .map((part) => Number.parseFloat(part));

    if (open !== -1 && !layer.includes('inset') && (lengths[3] ?? 0) > 0) {
      return layer.slice(colorStart, colorEnd);
    }
  }

  return undefined;
};

const readFocusStyles = async (control: Locator): Promise<FocusStyles> =>
  control.evaluate((element) => {
    const style = getComputedStyle(element);
    const root = getComputedStyle(document.documentElement);

    return {
      borderColor: style.borderTopColor,
      boxShadow: style.boxShadow,
      outlineColor: style.outlineColor,
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      tokens: {
        background: root.getPropertyValue('--background').trim(),
        card: root.getPropertyValue('--card').trim(),
        input: root.getPropertyValue('--input').trim(),
      },
    };
  });

const hasFocusIndicator = (styles: FocusStyles): boolean =>
  findRingColor(styles.boxShadow) !== undefined ||
  (styles.outlineStyle !== 'none' &&
    Number.parseFloat(styles.outlineWidth) > 0);

// Presses Tab until the control holds focus, as a keyboard user reaches it.
const tabTo = async (page: Page, target: Locator) => {
  for (let tabs = 0; tabs < MAXIMUM_TABS; tabs += 1) {
    const isFocused = await target.evaluate(
      (element) => element === document.activeElement
    );

    if (isFocused) return;
    await page.keyboard.press('Tab');
  }
};

// Each indicator (the painted ring and the border) against each surface, with
// the weaker of the two as the record's ratio.
const measureSurfaces = async ({
  control,
  page,
  styles,
  theme,
}: {
  control: string;
  page: Page;
  styles: FocusStyles;
  theme: string;
}) => {
  const ringCss = findRingColor(styles.boxShadow) ?? styles.outlineColor;
  const records = [];

  for (const surface of SURFACES) {
    const backdrop = styles.tokens[surface];
    const [surfaceColor] = await resolveColors(page, [
      {backdrop: styles.tokens.background, css: backdrop},
    ]);
    const [ring, borderRing] = await resolveColors(page, [
      {backdrop, css: ringCss},
      {backdrop, css: styles.borderColor},
    ]);
    const measured: [string, Rgba][] = [
      ['ring', ring],
      ['border-ring', borderRing],
    ];
    const ratios = measured.map(([indicator, color]) => ({
      indicator,
      ratio: contrastRatio(color, surfaceColor),
    }));
    let weakest = ratios[0];

    for (const candidate of ratios) {
      if (candidate.ratio < weakest.ratio) weakest = candidate;
    }
    records.push({
      control,
      indicator: weakest.indicator,
      kind: 'focus-ratio',
      ratio: weakest.ratio,
      ratios,
      surface,
      theme,
    });
  }

  return records;
};

for (const {control, id, locate} of CONTROLS) {
  for (const theme of ['light', 'dark'] as const) {
    test(`${control} keeps a focus indicator at 3:1 on every surface in ${theme} mode`, async ({
      page,
    }, testInfo) => {
      await loadStory(page, id, theme);
      await waitForRender(page);
      await expectTheme(page, theme);
      // The controls ease their colors in on focus; measure the settled
      // indicator, not a frame partway through the transition.
      await page.addStyleTag({
        content: '*, *::before, *::after { transition: none !important; }',
      });
      const target = locate(page);

      await expect(target).toBeVisible();
      await tabTo(page, target);
      await expect(target).toBeFocused();

      const styles = await readFocusStyles(target);

      expect(
        hasFocusIndicator(styles),
        `focused ${control} paints no ring and no outline (box-shadow: ${styles.boxShadow}; outline: ${styles.outlineStyle} ${styles.outlineWidth})`
      ).toBe(true);

      const records = await measureSurfaces({control, page, styles, theme});

      fs.writeFileSync(
        testInfo.outputPath('measurement.json'),
        JSON.stringify(records)
      );

      for (const record of records) {
        expect(
          record.ratio,
          `${control} ${record.indicator} on ${record.surface} in ${theme}`
        ).toBeGreaterThanOrEqual(MINIMUM_NON_TEXT_CONTRAST);
      }
    });
  }
}
