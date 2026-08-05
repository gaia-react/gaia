---
type: dependency
status: active
package: storybook
version: 10.4.6
role: component-development-and-visual-testing
created: 2026-04-20
updated: 2026-08-05
tags: [dependency, storybook]
---

# Storybook

Component-Driven Development environment. v10 with `@storybook/react-vite`.

## Companion packages

`@storybook/react-vite`, `@storybook/addon-docs`, `@storybook/addon-links`, `@vueless/storybook-dark-mode`, `storybook-react-i18next`, `chromatic`. `msw-storybook-addon` is in `package.json` but deliberately unused (stories seed from `@msw/data`). Storybook lint rules ship through the `@gaia-react/lint` config (spread as `...lint.storybook` in `eslint.config.mjs`), which supplies `eslint-plugin-storybook` transitively rather than as a direct `package.json` dependency.

See [[Storybook Stories]] module page.

## Vite version ceiling

Vite is held at 8.0.16. Vite 8.1.x (Rolldown 1.1.2 and up) builds a Storybook iframe bundle that calls the `__commonJS` interop helper without ever defining it, so the published Storybook throws `__commonJS is not defined` and Chromatic cannot extract stories. The app build (`react-router build`) is unaffected, so the local quality gate passes clean; only the Storybook build surfaces the fault, which makes [[Chromatic]] the gate that catches a `vite` 8.1.x bump. The distinction is precise: on 8.0.16 every `__commonJS` call site carries its helper definition, so the bundle runs; on 8.1.x (verified through 8.1.2) the bare `__commonJS` helper is called but never defined, declared, or imported into any chunk, while the sibling `__commonJSMin` and Rolldown's numbered `__commonJS$n` instances still emit correctly. The orphaned helper wraps a CommonJS chain (`react-i18next` → `hoist-non-react-statics` → `react-is`), and the fault only appears once that graph is large enough, so plain `vite` and a stripped-down Storybook both build clean. The `vite` companion group stays pinned to 8.0.16 until an upstream Rolldown release fixes the helper emission (tracked upstream at rolldown/rolldown#10048). The ceiling is enforced twice: `pnpm.overrides` pins the installed version, and `gaia.updateDepsHold` in `package.json` (`{"vite": "8.0"}`) tells the `/update-deps` skill to cap discovery at the 8.0 line so the hold survives in CI runs too, not just local snoozes.

## Environment values

The published preview inlines no environment values: `.storybook/preview-head.html` seeds `window.process = {env: {}}`, and no Vite `define` pipeline substitutes real values into the bundle, so a component reads every env field as `undefined` under a story, matching what a public Chromatic snapshot sees. A story that needs a value passes it as an arg rather than relying on an ambient env. `test/preview-env.test.ts` guards the Vitest half: the test suite does not merge `.env` file contents into `process.env`, since Vitest's workers already inherit the shell environment on their own and a wholesale merge would leak every local secret, `SESSION_SECRET` included, into every test file and its transitive dependencies.
