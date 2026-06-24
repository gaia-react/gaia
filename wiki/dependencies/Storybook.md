---
type: dependency
status: active
package: storybook
version: 10.4.6
role: component-development-and-visual-testing
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, storybook]
---

# Storybook

Component-Driven Development environment. v10 with `@storybook/react-vite`.

## Companion packages

`@storybook/react-vite`, `@storybook/addon-docs`, `@storybook/addon-links`, `@vueless/storybook-dark-mode`, `storybook-react-i18next`, `chromatic`. `msw-storybook-addon` is in `package.json` but deliberately unused (stories seed from `@msw/data`). Storybook lint rules ship through the `@gaia-react/lint` config (spread as `...lint.storybook` in `eslint.config.mjs`), which supplies `eslint-plugin-storybook` transitively rather than as a direct `package.json` dependency.

See [[Storybook Stories]] module page.
