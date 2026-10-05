---
type: decision
status: active
priority: 1
date: 2026-10-05
created: 2026-10-05
updated: 2026-10-05
tags: [decision, testing, storybook, vitest, a11y]
---

# Decision: Stories Are the Component Tests

A component or page is tested by a Storybook story with a `play` function, run by `@storybook/addon-vitest` in headless Chromium. No test file re-composes a story, and no DOM is emulated anywhere in the frontend: the browser projects run real Chromium and the `node` project has no DOM at all.

## Rationale

- One artifact. The story already carries the decorators, stubs, i18n and seed data the component needs, so the same file feeds Storybook, Chromatic, the Playwright story scan and the Vitest run. A separate test file that re-composes the story duplicates that wiring and lets the two drift.
- Real browser. Layout, focus, pointer and keyboard behavior, and axe contrast checks run in Chromium, not in an emulation that approximates it.
- Every story is also an accessibility test: `@storybook/addon-a11y` axe-checks each one, play or not. See [[Accessibility]].

## The three Vitest projects

`frontend/vitest.config.ts` defines three projects; read it for the exact membership instead of a copy here.

- `node`: pure and server code (`*.test.ts` outside hook folders), no DOM, with the MSW node server and the test-data reset in `test/setup.ts`.
- `browser`: hooks (`vitest-browser-react`) and any `*.test.tsx`, in Chromium, with `test/setup.browser.ts`.
- `storybook`: every story, through `storybookTest` from `@storybook/addon-vitest`. The preview annotations, addon presets included, apply automatically; no setup file in `.storybook/` calls `setProjectAnnotations`, because a file that does switches that automatic provisioning off.

All browser projects need Chromium. See [[Testing]] for the `pnpm install:browsers` prerequisite.

## What counts as a test to the harness

A story with an **effective play function**: its own `play`, an inherited meta-level `play`, or one reached through a spread or factory. A render-only story still runs under Vitest and still passes axe, but the RED and worthiness machinery does not count it as a test. A story tagged `!test` (story or meta level) is skipped by the Vitest run and the harness alike.

`.gaia/scripts/red-ledger/extract-story-signals.mjs` resolves the effective play and names each story the way addon-vitest does. Its header comment owns the supported CSF shapes and the refusal list. A shape it cannot resolve (a play bound to an import, a `meta.story()` story, `includeStories` or `excludeStories`, a computed export, a factory from another file) exits 7, and the merge-time [[Worthiness Presence Gate]] denies on that exit with the file and the extractor's one-line reason. The fix is to rewrite the story in a supported shape.

## Classification and gates

- A `*.stories.tsx` classifies **emergent** wherever it sits, before any path or AST check ([[Determinism Classifier]]). Stories are never RED-gated; the [[Worthiness Audit]] judges each play, and the presence gate requires a ledger line per story the PR changes.
- Hooks stay `*.test.ts` under a `hooks/` folder. They classify by the normal rules, so a deterministic hook keeps the RED demand ([[TDD RED Verification]]).
- When Chromium is missing, the RED capture hook says so and names `pnpm install:browsers` rather than recording nothing silently.

## Conventions

- **shadcn `ui` components** get render-only stories. A play belongs there only for behavior GAIA adds on top of the vendored component ([[shadcn Component Layer]]).
- **Story-scoped configuration** goes through props, not module state. `LanguageSelect` takes an optional `languages` prop (default: the app's full list), so a story passes the locales it needs without touching the app-wide list.
- **Router stub.** `stubs.reactRouter` (`frontend/test/stubs/react-router-stub.tsx`) accepts `actions` (a per-path action overriding the no-op entry for that path) and `destinations` (paths that render `Navigated to <path>` inside a main landmark so a play asserts arrival by text). The options may be a function of the story context, which lets a decorator read `fn()` spy args.
  - Router stubs do not nest: one `stubs.reactRouter` per story file, at meta level. Per-story variation goes through the function form.
  - An `actions` key must differ from the stub's `path`, because the main route matches first. A form posting to its own route is observed through the `action` option instead.
- **Callback spies.** A story that spies on a prop spreads `{...args}` last, so an `fn()` arg reaches the component. See [[Component Testing]].

See [[Testing]], [[Component Testing]], [[Storybook Stories]], [[Storybook]], [[Vitest]].
