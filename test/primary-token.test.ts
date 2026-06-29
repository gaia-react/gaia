import {describe, expect, test} from 'vitest';
// Runs in the project default (happy-dom) environment.
// The node environment was considered but the project setupFiles import storybook
// preview which accesses window.matchMedia at load time — that works in happy-dom
// but crashes in node.  File reads and string parsing work fine in happy-dom.
import {readFileSync} from 'node:fs';
import path from 'node:path';

// Read the source CSS; Vitest is invoked from the repo root (process.cwd())
const css = readFileSync(
  path.resolve(process.cwd(), 'app/styles/tailwind.css'),
  'utf-8'
);

// Collect every --color-primary-N: value declaration.
// Uses a specific oklch() value pattern to avoid open-ended backtracking.
const CSS_RE = /--color-primary-(\d+):\s+(oklch\([^)]+\))/g;
const declarations = [...css.matchAll(CSS_RE)].map(([, shade, value]) => ({
  shade: Number(shade),
  value: value.trim(),
}));

const EXPECTED_SHADES = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950];

// Hoisted to module scope — reused in every test.each iteration.
const OKLCH_INNER_RE = /oklch\(([^)]+)\)/i;

describe('primary-token', () => {
  test('exactly one primary scale — shades 50-950, 11 values, no duplicates', () => {
    const shades = declarations.map((d) => d.shade).toSorted((a, b) => a - b);
    expect(shades).toEqual(EXPECTED_SHADES);
  });

  test('no --color-claude-* declarations anywhere in tailwind.css', () => {
    expect(css).not.toMatch(/--color-claude-/);
  });

  test('no --color-accent-* declarations anywhere in tailwind.css', () => {
    expect(css).not.toMatch(/--color-accent-/);
  });

  test.each(EXPECTED_SHADES)(
    '--color-primary-%i has zero chroma (neutral oklch)',
    (shade) => {
      const decl = declarations.find((d) => d.shade === shade);
      expect(
        decl,
        `--color-primary-${shade} declaration not found`
      ).toBeDefined();

      const {value} = decl!;

      // Require oklch() form (C1 spec mandates oklch)
      expect(
        value,
        `primary-${shade}: expected oklch() form, got "${value}"`
      ).toMatch(/oklch\(/i);

      // Extract the inner content of oklch(...) and split on whitespace.
      // args[0]=L, args[1]=C (chroma), args[2]=H
      // Example: "oklch(43.9% 0 0deg)" → inner = "43.9% 0 0deg" → args[1] = "0"
      const oklchInner = OKLCH_INNER_RE.exec(value);
      expect(
        oklchInner,
        `primary-${shade}: could not parse oklch() inner args`
      ).not.toBeNull();

      const args = oklchInner![1].trim().split(/\s+/);
      const chroma = Number(args[1]);
      expect(
        chroma,
        `primary-${shade} chroma must be 0, got "${args[1]}"`
      ).toBe(0);
    }
  );
});
