// Runs in the project default (happy-dom) environment.
// The node environment was considered but the project setupFiles import storybook
// preview which accesses window.matchMedia at load time — that works in happy-dom
// but crashes in node.  Pure value-math works fine in happy-dom.
import {describe, expect, test} from 'vitest';

// ---------------------------------------------------------------------------
// WCAG relative-luminance helpers
// https://www.w3.org/TR/WCAG20/#relativeluminancedef
// ---------------------------------------------------------------------------

/** Convert a single sRGB channel (0-1) to linear light. */
const linearize = (c: number): number =>
  c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;

/** WCAG relative luminance from sRGB channels (0-1 each). */
const relativeLuminance = (r: number, g: number, b: number): number =>
  0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);

/** WCAG contrast ratio between two relative luminances. */
const contrastRatio = (lum1: number, lum2: number): number => {
  const lighter = Math.max(lum1, lum2);
  const darker = Math.min(lum1, lum2);

  return (lighter + 0.05) / (darker + 0.05);
};

// ---------------------------------------------------------------------------
// Primary-scale luminances
//
// C1 spec (README.md §C1) defines each shade as oklch(L% 0 0deg) — zero
// chroma, neutral gray.  For oklch(L, 0, *) the XYZ Y channel = L³ (within
// 0.1 % error), and for neutral grays WCAG relative luminance equals the
// linear sRGB value which also equals L³.  All values verified below.
//
// L values (from tailwind.css, divide % by 100):
//   primary-200 → L = 0.922  → lum ≈ 0.922³ ≈ 0.7838
//   primary-300 → L = 0.87   → lum ≈ 0.87³  ≈ 0.6585
//   primary-400 → L = 0.708  → lum ≈ 0.708³ ≈ 0.3549
//   primary-500 → L = 0.556  → lum ≈ 0.556³ ≈ 0.1722
//   primary-600 → L = 0.439  → lum ≈ 0.439³ ≈ 0.0846
//   primary-700 → L = 0.371  → lum ≈ 0.371³ ≈ 0.0511
//   primary-950 → L = 0.145  → lum ≈ 0.145³ ≈ 0.0030
// ---------------------------------------------------------------------------

const primaryLum = (L: number): number => L ** 3;

const LUM = {
  200: primaryLum(0.922),
  300: primaryLum(0.87),
  400: primaryLum(0.708),
  500: primaryLum(0.556),
  600: primaryLum(0.439),
  700: primaryLum(0.371),
  950: primaryLum(0.145),
  // dark bg: Tailwind gray-900 = oklch(21% 0.034 264.665) ≈ sRGB #101828
  // Computed with WCAG formula from the 8-bit sRGB values r=16 g=24 b=40
  gray900: relativeLuminance(16 / 255, 24 / 255, 40 / 255),
  white: 1,
} as const;

// ---------------------------------------------------------------------------
// Text contrast (≥ 4.5:1)
// ---------------------------------------------------------------------------

describe('primary-contrast — text (≥ 4.5:1)', () => {
  test('white on primary-600 primary button fill — light + dark', () => {
    // primary-600 is the filled background; white is the button label
    const ratio = contrastRatio(LUM.white, LUM[600]);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test('primary-600 link hover vs white page background — light theme', () => {
    const ratio = contrastRatio(LUM[600], LUM.white);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test('primary-300 link hover vs gray-900 page background — dark theme', () => {
    const ratio = contrastRatio(LUM[300], LUM.gray900);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test('white selection text vs primary-700 selection background — light theme', () => {
    // selection:bg-primary-700 selection:text-white
    const ratio = contrastRatio(LUM.white, LUM[700]);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test('primary-950 selection text vs primary-300 selection background — dark theme', () => {
    // dark:selection:bg-primary-300 dark:selection:text-primary-950
    const ratio = contrastRatio(LUM[950], LUM[300]);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test('primary-200 Toast info icon vs primary-600 Toast info fill — both themes', () => {
    // Toast info: bg-primary-600, icon text-primary-200
    const ratio = contrastRatio(LUM[200], LUM[600]);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });
});

// ---------------------------------------------------------------------------
// Non-text contrast (≥ 3:1)
// ---------------------------------------------------------------------------

describe('primary-contrast — non-text (≥ 3:1)', () => {
  // Focus ring: focus-visible:border-primary-600 (light) / dark:focus-visible:border-primary-400 (dark)
  test('focus border primary-600 vs white input background — light theme', () => {
    const ratio = contrastRatio(LUM[600], LUM.white);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });

  test('focus border primary-400 vs gray-900 input background — dark theme', () => {
    const ratio = contrastRatio(LUM[400], LUM.gray900);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });

  // Checked fill: checked:bg-primary-600 (light) / dark:checked:bg-primary-500 (dark)
  test('checked fill primary-600 vs white page background — light theme', () => {
    const ratio = contrastRatio(LUM[600], LUM.white);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });

  test('checked fill primary-500 vs gray-900 page background — dark theme', () => {
    const ratio = contrastRatio(LUM[500], LUM.gray900);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });

  // Checked border: checked:border-primary-500 — the component boundary that frames
  // the filled checkbox.  This passes in both themes, satisfying the boundary-contrast
  // clause of WCAG 1.4.11 independently of the fill-vs-background issue above.
  test('checked border primary-500 vs white page background — light theme', () => {
    const ratio = contrastRatio(LUM[500], LUM.white);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });

  test('checked border primary-500 vs gray-900 page background — dark theme', () => {
    const ratio = contrastRatio(LUM[500], LUM.gray900);
    expect(ratio).toBeGreaterThanOrEqual(3);
  });
});
