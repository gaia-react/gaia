import {describe, expect, test} from 'vitest';
// Runs in the project default (happy-dom) environment; see primary-token.test.ts.
import {readFileSync} from 'node:fs';
import path from 'node:path';

const stylesDirectory = path.resolve(import.meta.dirname, '../app/styles');
const tokenCss = readFileSync(path.join(stylesDirectory, 'theme.css'), 'utf-8');
const tailwindCss = readFileSync(
  path.join(stylesDirectory, 'tailwind.css'),
  'utf-8'
);

// Stock base-nova neutral values, as the shadcn init emitted them.
const stockRoot: Record<string, string> = {
  '--accent': 'oklch(0.97 0 0)',
  '--accent-foreground': 'oklch(0.205 0 0)',
  '--background': 'oklch(1 0 0)',
  '--border': 'oklch(0.922 0 0)',
  '--card': 'oklch(1 0 0)',
  '--card-foreground': 'oklch(0.145 0 0)',
  '--chart-1': 'oklch(0.87 0 0)',
  '--chart-2': 'oklch(0.556 0 0)',
  '--chart-3': 'oklch(0.439 0 0)',
  '--chart-4': 'oklch(0.371 0 0)',
  '--chart-5': 'oklch(0.269 0 0)',
  '--destructive': 'oklch(0.577 0.245 27.325)',
  '--foreground': 'oklch(0.145 0 0)',
  '--input': 'oklch(0.922 0 0)',
  '--muted': 'oklch(0.97 0 0)',
  '--muted-foreground': 'oklch(0.556 0 0)',
  '--popover': 'oklch(1 0 0)',
  '--popover-foreground': 'oklch(0.145 0 0)',
  '--primary': 'oklch(0.205 0 0)',
  '--primary-foreground': 'oklch(0.985 0 0)',
  '--radius': '0.625rem',
  '--ring': 'oklch(0.708 0 0)',
  '--secondary': 'oklch(0.97 0 0)',
  '--secondary-foreground': 'oklch(0.205 0 0)',
  '--sidebar': 'oklch(0.985 0 0)',
  '--sidebar-accent': 'oklch(0.97 0 0)',
  '--sidebar-accent-foreground': 'oklch(0.205 0 0)',
  '--sidebar-border': 'oklch(0.922 0 0)',
  '--sidebar-foreground': 'oklch(0.145 0 0)',
  '--sidebar-primary': 'oklch(0.205 0 0)',
  '--sidebar-primary-foreground': 'oklch(0.985 0 0)',
  '--sidebar-ring': 'oklch(0.708 0 0)',
};

const stockDark: Record<string, string> = {
  '--accent': 'oklch(0.269 0 0)',
  '--accent-foreground': 'oklch(0.985 0 0)',
  '--background': 'oklch(0.145 0 0)',
  '--border': 'oklch(1 0 0 / 10%)',
  '--card': 'oklch(0.205 0 0)',
  '--card-foreground': 'oklch(0.985 0 0)',
  '--chart-1': 'oklch(0.87 0 0)',
  '--chart-2': 'oklch(0.556 0 0)',
  '--chart-3': 'oklch(0.439 0 0)',
  '--chart-4': 'oklch(0.371 0 0)',
  '--chart-5': 'oklch(0.269 0 0)',
  '--destructive': 'oklch(0.704 0.191 22.216)',
  '--foreground': 'oklch(0.985 0 0)',
  '--input': 'oklch(1 0 0 / 15%)',
  '--muted': 'oklch(0.269 0 0)',
  '--muted-foreground': 'oklch(0.708 0 0)',
  '--popover': 'oklch(0.205 0 0)',
  '--popover-foreground': 'oklch(0.985 0 0)',
  '--primary': 'oklch(0.922 0 0)',
  '--primary-foreground': 'oklch(0.205 0 0)',
  '--ring': 'oklch(0.556 0 0)',
  '--secondary': 'oklch(0.269 0 0)',
  '--secondary-foreground': 'oklch(0.985 0 0)',
  '--sidebar': 'oklch(0.205 0 0)',
  '--sidebar-accent': 'oklch(0.269 0 0)',
  '--sidebar-accent-foreground': 'oklch(0.985 0 0)',
  '--sidebar-border': 'oklch(1 0 0 / 10%)',
  '--sidebar-foreground': 'oklch(0.985 0 0)',
  '--sidebar-primary': 'oklch(0.488 0.243 264.376)',
  '--sidebar-primary-foreground': 'oklch(0.985 0 0)',
  '--sidebar-ring': 'oklch(0.556 0 0)',
};

// The only values GAIA changes, all accessibility (contrast) fixes. The ring
// is darkened in light and lightened in dark so the focus ring, drawn at half
// opacity, still measures 3:1 against the page, card and input surfaces.
const rootOverrides: Record<string, string> = {
  '--destructive': 'oklch(0.52 0.235 27.325)',
  '--muted-foreground': 'oklch(0.5 0 0)',
  '--ring': 'oklch(0.2 0 0)',
};

const darkOverrides: Record<string, string> = {
  '--ring': 'oklch(0.92 0 0)',
};

const blockPattern = (selector: string): RegExp =>
  new RegExp(String.raw`(?:^|\n)${selector}\s*\{([^}]*)\}`);

const parseBlock = (selector: string): Map<string, string> => {
  const body = (blockPattern(selector).exec(tokenCss)?.[1] ?? '').replaceAll(
    /\/\*[^*]*\*\//g,
    ''
  );
  const declarations = new Map<string, string>();

  for (const declaration of body.split(';')) {
    const separator = declaration.indexOf(':');

    if (declaration.trimStart().startsWith('--') && separator !== -1) {
      declarations.set(
        declaration.slice(0, separator).trim(),
        declaration.slice(separator + 1).trim()
      );
    }
  }

  return declarations;
};

const rootTokens = parseBlock(':root');
const darkTokens = parseBlock(String.raw`\.dark`);

// Percentage lightness and `deg` hue, the form the stylelint config enforces.
const stylelintOklch =
  /^oklch\(\d+(?:\.\d+)?% \d+(?:\.\d+)? \d+(?:\.\d+)?deg(?: \/ \d+(?:\.\d+)?%)?\)$/;

// Normalizes either spelling to numbers so 52% and 0.52 compare equal.
const toNumbers = (value: string): number[] => {
  const match = /oklch\(([^)]+)\)/.exec(value);
  const [channels, alpha] = (match?.[1] ?? '').split('/');
  const [lightness, chroma, hue] = channels.trim().split(/\s+/);
  const numbers = [
    lightness.endsWith('%') ?
      Number.parseFloat(lightness) / 100
    : Number(lightness),
    Number.parseFloat(chroma),
    Number.parseFloat(hue),
  ];

  if (alpha) {
    numbers.push(Number.parseFloat(alpha) / 100);
  }

  return numbers;
};

const sameColor = (actual: string, expected: string): boolean => {
  const actualNumbers = toNumbers(actual);
  const expectedNumbers = toNumbers(expected);

  return (
    actualNumbers.length === expectedNumbers.length &&
    actualNumbers.every(
      (number, index) => Math.abs(number - expectedNumbers[index]) < 1e-9
    )
  );
};

const requiredTokens = Object.keys(stockDark);

describe('theme tokens', () => {
  test.each(requiredTokens)('%s is defined in :root', (name) => {
    expect(rootTokens.has(name)).toBe(true);
  });

  test.each(requiredTokens)('%s is defined in .dark', (name) => {
    expect(darkTokens.has(name)).toBe(true);
  });

  test('--radius is defined', () => {
    expect(rootTokens.get('--radius')).toBe('0.625rem');
  });

  test.each([...rootTokens.entries()].filter(([name]) => name !== '--radius'))(
    ':root %s is in stylelint oklch form',
    (_name, value) => {
      expect(value).toMatch(stylelintOklch);
    }
  );

  test.each([...darkTokens.entries()])(
    '.dark %s is in stylelint oklch form',
    (_name, value) => {
      expect(value).toMatch(stylelintOklch);
    }
  );

  test.each(Object.entries(rootOverrides))(
    ':root %s keeps the contrast override',
    (name, expected) => {
      expect(sameColor(rootTokens.get(name) ?? '', expected)).toBe(true);
    }
  );

  test.each(
    Object.entries(stockRoot).filter(
      ([name]) => name !== '--radius' && !(name in rootOverrides)
    )
  )(':root %s equals the stock value', (name, stock) => {
    expect(sameColor(rootTokens.get(name) ?? '', stock)).toBe(true);
  });

  test.each(Object.entries(darkOverrides))(
    '.dark %s keeps the contrast override',
    (name, expected) => {
      expect(sameColor(darkTokens.get(name) ?? '', expected)).toBe(true);
    }
  );

  test.each(
    Object.entries(stockDark).filter(([name]) => !(name in darkOverrides))
  )('.dark %s equals the stock value', (name, stock) => {
    expect(sameColor(darkTokens.get(name) ?? '', stock)).toBe(true);
  });

  test('declares color-scheme for both themes', () => {
    expect(blockPattern(':root').exec(tokenCss)?.[1]).toMatch(
      /color-scheme:\s*light;/
    );
    expect(blockPattern(String.raw`\.dark`).exec(tokenCss)?.[1]).toMatch(
      /color-scheme:\s*dark;/
    );
  });

  test('tailwind.css imports the token file and defines no token block', () => {
    expect(tailwindCss).toMatch(/@import\s+['"]\.\/theme\.css['"];/);
    expect(tailwindCss).not.toMatch(/(?:^|\n):root\s*\{/);
    expect(tailwindCss).not.toMatch(/(?:^|\n)\.dark\s*\{/);
  });
});
