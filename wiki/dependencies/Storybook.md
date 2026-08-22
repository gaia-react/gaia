---
type: dependency
status: active
package: storybook
version: 10.5.8
role: component-development-and-visual-testing
created: 2026-04-20
updated: 2026-08-22
tags: [dependency, storybook]
---

# Storybook

Component-Driven Development environment. v10 with `@storybook/react-vite`.

## Companion packages

`@storybook/react-vite`, `@storybook/addon-docs`, `@storybook/addon-links`, `@vueless/storybook-dark-mode`, `storybook-react-i18next`, `chromatic`. `msw-storybook-addon` is in `package.json` but deliberately unused (stories seed from `@msw/data`). Storybook lint rules ship through the `@gaia-react/lint` config (spread as `...lint.storybook` in `eslint.config.mjs`), which supplies `eslint-plugin-storybook` transitively rather than as a direct `package.json` dependency.

See [[Storybook Stories]] module page.

## Vite and the Rolldown CommonJS fault

Vite tracks the current release; no version ceiling applies. Vite 8.1.x (Rolldown 1.1.2 and up) built a Storybook iframe bundle that called the `__commonJS` interop helper without ever defining it, so the published Storybook threw `__commonJS is not defined` and Chromatic could not extract stories. The orphaned helper wrapped a CommonJS chain (`react-i18next` → `hoist-non-react-statics` → `react-is`), and the fault only appeared once that graph was large enough, so plain `vite` and a stripped-down Storybook both built clean. Vite 8.2.x emits the helper correctly and the ceiling is gone: every chunk that calls bare `__commonJS` also defines it, and the iframe bundle no longer references it at all.

The fault is worth recognizing because it is invisible to the ordinary quality gate. The app build (`react-router build`) is unaffected, so `pnpm build` passes clean; only the Storybook build surfaces it, which makes [[Chromatic]] the gate that catches it. That gate has a hole on dependency bumps: `.github/workflows/chromatic.yml` short-circuits on a `chore(deps):` or `chore(deps-dev):` subject, so a `vite` bump arriving through `/update-deps` skips Chromatic entirely. Verify a `vite` bump locally instead:

```bash
pnpm build-storybook
# Every chunk calling bare __commonJS must also define it.
for f in $(grep -rl "__commonJS" storybook-static/); do
  grep -q "var __commonJS *=" "$f" || echo "ORPHAN: $f"
done
```

A load of `storybook-static/iframe.html` that reports zero console errors and a story index with the expected entry count confirms the bundle runs. The sibling `__commonJSMin` and Rolldown's numbered `__commonJS$n` instances always emitted correctly, so only the bare helper is diagnostic.

## Environment values

The published preview inlines no environment values: `.storybook/preview-head.html` seeds `window.process = {env: {}}`, and no Vite `define` pipeline substitutes real values into the bundle, so a component reads every env field as `undefined` under a story, matching what a public Chromatic snapshot sees. A story that needs a value passes it as an arg rather than relying on an ambient env. `test/preview-env.test.ts` guards the Vitest half: the test suite does not merge `.env` file contents into `process.env`, since Vitest's workers already inherit the shell environment on their own and a wholesale merge would leak every local secret, `SESSION_SECRET` included, into every test file and its transitive dependencies.
