/**
 * Companion-group resolution for `gaia update-deps run`.
 *
 * The skill at `.claude/skills/update-deps/SKILL.md` (Phase 2) defines a
 * fixed table that maps each outdated package to a group so the wave is
 * processed atomically. This module replicates that table deterministically
 * for the CLI primitive — the LLM-driven skill and the CLI must agree on
 * which packages move together.
 *
 * Resolution rules:
 *   - Exact-name matches win first.
 *   - Glob-style prefixes (`@storybook/*`, `eslint-plugin-*`, etc.) match
 *     next, longest-prefix-first.
 *   - The `prettier` group's `eslint-config-prettier` and
 *     `eslint-plugin-prettier` exact matches MUST take precedence over the
 *     `eslint` group's broader `eslint-config-*` / `eslint-plugin-*`
 *     prefixes — that's why exact-name matches are checked first.
 *   - `msw-storybook-addon` belongs to both `storybook` and `msw` per the
 *     SKILL table; we route it to `storybook` (more specific addon scope).
 *   - Anything unmatched becomes `singleton:<name>`.
 */

type GroupRule = {
  /**
   * Exact package names (highest precedence). Listed packages that are not
   * outdated still count as group members when computing wave grouping —
   * but only outdated packages appear in the emitted JSON.
   */
  readonly exactNames: readonly string[];
  readonly group: string;
  /** Glob prefixes ending in `*`, e.g. `@storybook/`. Matched after exact. */
  readonly prefixes?: readonly string[];
};

/**
 * Order matters only for the singleton fallback — exact / prefix lookups
 * are precomputed below into maps. The `prettier` rule precedes `eslint`
 * not because of ordering but because exact-name lookup runs first.
 */
const GROUP_RULES: readonly GroupRule[] = [
  {
    exactNames: [
      '@react-router/dev',
      '@react-router/fs-routes',
      '@react-router/node',
      '@react-router/remix-routes-option-adapter',
      '@react-router/serve',
      'react-router',
      'react-router-dom',
    ],
    group: 'react-router',
  },
  {
    exactNames: ['@types/react', '@types/react-dom', 'react', 'react-dom'],
    group: 'react',
  },
  {
    exactNames: [
      '@tailwindcss/forms',
      '@tailwindcss/typography',
      '@tailwindcss/vite',
      'prettier-plugin-tailwindcss',
      'tailwindcss',
    ],
    group: 'tailwindcss',
  },
  {
    exactNames: [
      '@vueless/storybook-dark-mode',
      'eslint-plugin-storybook',
      'msw-storybook-addon',
      'storybook',
      'storybook-react-i18next',
    ],
    group: 'storybook',
    prefixes: ['@storybook/'],
  },
  {
    exactNames: [
      '@vitest/coverage-v8',
      '@vitest/eslint-plugin',
      '@vitest/ui',
      'vitest',
    ],
    group: 'vitest',
  },
  {
    exactNames: ['@playwright-testing-library/test', '@playwright/test'],
    group: 'playwright',
  },
  {
    exactNames: [
      '@testing-library/dom',
      '@testing-library/jest-dom',
      '@testing-library/react',
      '@testing-library/user-event',
    ],
    group: 'testing-library',
  },
  {
    exactNames: ['@types/node', 'typescript'],
    group: 'typescript',
  },
  {
    exactNames: [
      'i18next',
      'i18next-browser-languagedetector',
      'react-i18next',
      'remix-i18next',
    ],
    group: 'i18next',
  },
  {
    // msw-storybook-addon is intentionally claimed by `storybook` above.
    exactNames: ['msw'],
    group: 'msw',
  },
  {
    exactNames: ['@vitejs/plugin-react', 'vite'],
    group: 'vite',
  },
  {
    exactNames: ['@conform-to/react', '@conform-to/zod', 'zod'],
    group: 'zod-conform',
  },
  {
    exactNames: [],
    group: 'fontawesome',
    prefixes: ['@fortawesome/'],
  },
  {
    exactNames: ['stylelint', 'stylelint-order'],
    group: 'stylelint',
    prefixes: ['stylelint-config-'],
  },
  // Prettier MUST come before eslint so its eslint-config-prettier and
  // eslint-plugin-prettier exact entries beat eslint's broader prefixes.
  {
    exactNames: ['eslint-config-prettier', 'eslint-plugin-prettier', 'prettier'],
    group: 'prettier',
  },
  {
    exactNames: ['@eslint/compat', '@eslint/js', 'eslint'],
    group: 'eslint',
    prefixes: ['eslint-config-', 'eslint-plugin-'],
  },
  {
    exactNames: ['husky', 'lint-staged'],
    group: 'husky',
  },
];

const buildExactIndex = (
  rules: readonly GroupRule[]
): Readonly<Record<string, string>> => {
  const out: Record<string, string> = {};

  for (const rule of rules) {
    for (const name of rule.exactNames) {
      // Exact-name conflicts would mean a package is in two groups; if that
      // ever happens, the later rule wins. We do not have any such overlap
      // today.
      out[name] = rule.group;
    }
  }

  return out;
};

const EXACT_INDEX: Readonly<Record<string, string>> =
  buildExactIndex(GROUP_RULES);

type PrefixMatch = {
  readonly group: string;
  readonly prefix: string;
};

const buildPrefixList = (rules: readonly GroupRule[]): readonly PrefixMatch[] => {
  const out: PrefixMatch[] = [];

  for (const rule of rules) {
    for (const prefix of rule.prefixes ?? []) {
      out.push({group: rule.group, prefix});
    }
  }

  // Longest prefix wins so e.g. `@storybook/` beats `@s` if both existed.
  return out.toSorted((a, b) => b.prefix.length - a.prefix.length);
};

const PREFIX_LIST: readonly PrefixMatch[] = buildPrefixList(GROUP_RULES);

/**
 * Map a package name to its companion group. Packages outside every rule
 * fall back to `singleton:<name>` so the JSON consumer can treat groups
 * uniformly.
 */
export const resolveGroup = (name: string): string => {
  const exact = EXACT_INDEX[name];

  if (exact !== undefined) return exact;

  for (const entry of PREFIX_LIST) {
    if (name.startsWith(entry.prefix)) return entry.group;
  }

  return `singleton:${name}`;
};

/**
 * Given a companion group name and the full set of package names present in
 * `package.json`, return all members of that group. This is used to expand
 * groups beyond what `pnpm outdated` flagged — so all siblings move together.
 *
 * Singletons (group name starts with "singleton:") always return an empty
 * array — they have no companion members to expand.
 */
export const resolveGroupMembers = (
  groupName: string,
  allPackageNames: readonly string[]
): readonly string[] => {
  if (groupName.startsWith('singleton:')) return [];

  const out: string[] = [];

  for (const pkgName of allPackageNames) {
    if (resolveGroup(pkgName) === groupName) {
      out.push(pkgName);
    }
  }

  return out;
};
