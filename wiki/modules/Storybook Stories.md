---
type: module
path: .storybook/
status: active
language: typescript
purpose: Storybook setup with React Router, i18n, dark mode, and Chromatic snapshots
depends_on:
  - '[[Storybook]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-05-04
tags: [module, storybook, testing]
---

# Storybook Stories

Storybook v10 with the `@storybook/react-vite` framework. Configured to discover `*.stories.tsx` anywhere in `app/`.

## Why Storybook is also the test driver

`composeStory` lets Vitest tests reuse the same story setup, so a single source of truth drives both visual regression (Chromatic) and integration tests. See [[Component Testing]] and [[Testing]].

## Decorator stack: the load-bearing convention

Outermost to innermost: **`WrapDecorator → ChromaticDecorator → ToastDecorator`**. The order matters because each decorator depends on the layout established by the one outside it.

- `WrapDecorator`: reads `parameters.wrap` and wraps the story (use `parameters: {wrap: 'p-4'}` for padding instead of hardcoding divs in stories)
- `ChromaticDecorator`: Chromatic snapshots only; renders story twice (light + dark, `50vh` each). `excludeDark: true` suppresses the dark render
- `ToastDecorator`: appends `<Toast />` after every story so any toast call from a story is rendered

Interactive sessions skip the Chromatic decorator: `WrapDecorator → ToastDecorator`.

## Stubs

`test/stubs/` provides story-level decorators (`stubs.state()`, `stubs.reactRouter()`). Apply as `[stubs.state(), stubs.reactRouter()]` when both are needed. See `.claude/rules/storybook.md` for full stub options (`action`, `loader`, `path`, `routes`).

## Dark-mode handling

`preview.ts` configures `darkClass: ['dark', 'bg-gray-900', 'text-white']` and `lightClass: ['light', 'bg-white', 'text-gray-900']`; applied to the preview document root when the toolbar toggle fires, matching the Tailwind `dark:` variant convention used throughout the codebase. `stylePreview: true` extends the theme to Storybook chrome.

## i18n in stories

`storybook-react-i18next` is wired to the project's own `~/i18n` config. Toolbar exposes the configured locales. Inside story functions, call `useTranslation()` normally; no extra setup. Per-locale content variation (e.g. stress-testing long CJK strings) is handled inside the story by reading `i18n.language`.

## Test data: no MSW addon

`msw-storybook-addon` ships in devDependencies but is **not wired into Storybook config**; stories do no API-level mocking. Pull seed data from the `@msw/data` collections in `test/mocks/database` directly. See `.claude/rules/storybook.md` for the usage pattern. The unused addon is a removal candidate.

For the current `.storybook/` file inventory, query Serena (`.claude/rules/code-search.md`).
