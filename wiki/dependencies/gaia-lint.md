---
type: dependency
status: active
package: '@gaia-react/lint'
role: lint-config
created: 2026-04-27
updated: 2026-04-27
tags: [dependency, lint, eslint]
---

# @gaia-react/lint

## What it is

GAIA's lint config, extracted to a standalone package under `github.com/gaia-react/lint`. Currently ESLint flat-config; engine-neutral name supports a future Biome migration without consumer breakage.

## Why a separate repo

- Reuse across gaia-react org repos (gaia, create-gaia bootstrapper, branding, docs, future apps) without copy/paste drift.
- Single upgrade path — bump `@gaia-react/lint` instead of chasing 21 plugin upgrades per consumer.
- Engine swap freedom — name doesn't mention ESLint, so a v2 Biome backend is a non-breaking rename.

## Where rules live

Source of truth: `gaia-lint/src/configs/*.ts` (per export — `base.ts`, `react.ts`, `style-hygiene.ts`, `guardrails.ts`, `testing.ts`, `storybook.ts`, `playwright.ts`, `prettier.ts`, `better-tailwind.ts`, `ignores.ts`). Custom plugins (`no-enum`, `no-switch`) live in `gaia-lint/src/plugins/`.

GAIA's `eslint.config.mjs` is a thin consumer — it spreads the package's exported arrays and adds GAIA-specific overrides last.

## Override pattern

Spread package configs first, then GAIA-specific overrides last (flat-config last-write-wins):

```js
import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

export default defineConfig([
  ...gaiaLint.ignores({gitignore: '.gitignore'}),
  ...gaiaLint.base,
  ...gaiaLint.react,
  ...gaiaLint.testing,
  ...gaiaLint.storybook,
  ...gaiaLint.playwright,
  ...gaiaLint.styleHygiene,
  ...gaiaLint.guardrails,
  ...gaiaLint.betterTailwind({entryPoint: './app/styles/tailwind.css'}),
  ...gaiaLint.prettier,
  // Project-specific overrides go LAST
  {
    files: ['app/some/path/**'],
    rules: {'some-rule': 'off'},
  },
]);
```

## When to edit

- Edit `@gaia-react/lint` when the rule should propagate to **all** consumers.
- Edit GAIA's `eslint.config.mjs` only when the override is **GAIA-specific** (folder layout, app-only relaxations).

## See also

- [[ESLint Fixes]]
- [[Quality Gate]]
