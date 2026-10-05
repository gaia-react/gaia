---
type: module
path: frontend/.storybook/
status: active
language: typescript
purpose: Storybook setup with React Router, i18n, dark mode, and Chromatic snapshots
depends_on:
  - '[[Storybook]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-10-05
tags: [module, storybook, testing]
---

# Storybook Stories

Storybook v10 with the `@storybook/react-vite` framework. Configured to discover `*.stories.tsx` anywhere in `frontend/app/`.

## Why Storybook is also the test driver

`@storybook/addon-vitest` runs every story as a Vitest test in headless Chromium, and a story's `play` function holds its assertions, so one source of truth drives the component test, visual regression (Chromatic) and the Playwright story scan. `@storybook/addon-a11y` axe-checks each story. See [[Stories as Tests]], [[Component Testing]] and [[Testing]].

## Decorator stack: the load-bearing convention

Outermost to innermost: **`WrapDecorator → ChromaticDecorator → ToastDecorator`**. The order matters because each decorator depends on the layout established by the one outside it.

- `WrapDecorator`: reads `parameters.wrap` and wraps the story (use `parameters: {wrap: 'p-4'}` for padding instead of hardcoding divs in stories)
- `ChromaticDecorator`: Chromatic snapshots only; renders the story once, puts `dark` on `<html>` when the `theme` global is `dark`, and clears `sessionStorage` before each snapshot
- `ToastDecorator`: renders a bare `<Toaster />` from `~/components/ui/toast` after every story, so any toast call from a story is rendered

Interactive sessions skip the Chromatic decorator: `WrapDecorator → ToastDecorator`.

## Stubs

`frontend/test/stubs/` provides story-level decorators (`stubs.state()`, `stubs.reactRouter()`). Apply as `[stubs.state(), stubs.reactRouter()]` when both are needed. See `frontend/.claude/rules/storybook.md` for full stub options (`action`, `loader`, `path`, `routes`, `actions`, `destinations`).

## Dark-mode handling

`preview.ts` sets `darkClass` and `lightClass` to the `dark` or `light` class plus the role-token utilities `bg-background` and `text-foreground`, applied to the preview document root when the toolbar toggle fires, so the `.dark` token block in `theme.css` drives both themes. `stylePreview: true` extends the theme to Storybook chrome.

Chromatic loads only the preview iframe, so the toolbar toggle never fires there. Instead `frontend/.storybook/modes.ts` defines a `light` and a `dark` [[Chromatic]] mode, each setting the `theme` global (declared in `preview.ts` `initialGlobals`, since Storybook drops an undeclared global) and the 1280px viewport. Chromatic snapshots every story once per mode, and `ChromaticDecorator` applies the global. Vitest and the Playwright scan never add that decorator, so `theme` changes nothing there.

## i18n in stories

`storybook-react-i18next` is wired to the project's own `~/i18n` config. Toolbar exposes the configured locales. Inside story functions, call `useTranslation()` normally; no extra setup. Per-locale content variation (e.g. stress-testing long CJK strings) is handled inside the story by reading `i18n.language`.

## Test data: no MSW addon

`msw-storybook-addon` ships in devDependencies but is **not wired into Storybook config**; stories do no API-level mocking. Pull seed data from the `@msw/data` collections in `frontend/test/mocks/database` directly. See `frontend/.claude/rules/storybook.md` for the usage pattern. The unused addon is a removal candidate.

For the current `frontend/.storybook/` file inventory, query Serena (`.claude/rules/code-search.md`).
