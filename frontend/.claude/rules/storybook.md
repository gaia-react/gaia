---
paths:
  - 'app/**/*.stories.tsx'
  - '.storybook/**/*'
---

# Storybook Conventions

The `/new-component` command scaffolds the canonical story shape. This rule covers what to do when authoring or extending a story beyond that scaffold.

## Stories are the tests

A story is a test. `@storybook/addon-vitest` runs every story in headless Chromium (run `pnpm install:browsers` once), and the story passes when it renders and its play function, if any, finishes without an assertion failing. addon-a11y then axe-checks the rendered story, so a violation fails the story with no extra test. Components and pages have no `.test.tsx` beside their stories; the play function is where the assertions live. Import `expect`, `fn`, `userEvent`, `waitFor`, `within` (and `fireEvent` when a native event has no `userEvent` equivalent) from `storybook/test`; it re-exports the jest-dom matchers and user-event.

## When to write a story

Write a story with a play function for every GAIA behavior a component or page owns: each interaction, state transition and error path, one story per behavior, named for the behavior (`PointerChoiceSubmits`, not `Test1`). A render-only story (no play) still runs and passes axe, and is complete only for a component with no interactive behavior. For an interactive component the plays assert a keyboard path and a focus outcome. Skip stories only for pure-utility components with no visual output (e.g. context providers, HOCs with no markup); those get a `node` or `browser` Vitest test instead.

Configure a story through props and args (for example `LanguageSelect`'s `languages` prop), not by mutating shared constants.

## Accessibility

addon-a11y runs on every story with the WCAG 2.0/2.1 A and AA tags and fails on a violation of any impact; only the `region` rule is off, because a story renders a fragment outside the page landmarks. The config is `.storybook/a11y.ts`, which `.storybook/preview.ts` sets as `parameters.a11y`. Do not opt a story out (`parameters.a11y.test: 'todo'` or `'off'`, `parameters.a11y.disable`, the `a11y.manual` global, the `!test` tag, or any per-story `parameters.a11y.context`, `config` or `options` that differs from the shared config); fix the markup instead. This check is the only light-theme axe pass a story gets, since the Playwright scan covers dark, so `test/story-a11y-opt-out.test.tsx` fails on any story carrying one of those opt-outs, unless its id and a reason are recorded there. Page landmark and heading checks are play assertions (one `main`, one level-1 heading).

## Vitest and Chromatic

The Chromatic decorator (`ChromaticDecorator`) is added only when Chromatic itself snapshots, so it does not run under Vitest. Every render shows the story once: Vitest renders it in the current theme, and Chromatic renders it once per mode (light, then dark), running the play function in each.

## File location

A story or test is `tests/<source basename>.<kind>.tsx` beside its source: `index.tsx` -> `tests/index.stories.tsx`, `page.tsx` -> `tests/page.stories.tsx`, `ui/button.tsx` -> `ui/tests/button.stories.tsx`. A vendored `components/ui/<name>.tsx` file's stories live at `components/ui/tests/<name>.stories.tsx` (the flat ui folder's location, distinct from a component folder's `tests/index.stories.tsx`); ui stories render each variant value and the invalid and disabled states.

## Typing

Use `Meta` and `StoryFn` from `@storybook/react-vite`. Never use `Story` (deprecated alias).

## Title convention

Slash-separated PascalCase display segments of the path under `app/`, with no layout group: `Pages/Contact`, `Pages/Index/PromoBanner`, `Components/PriceTag`.

## Decorator order

Apply stubs outermost → innermost: `state` then `reactRouter`. The global Query decorator (present only after Query is on) sits outside both, so each story gets a fresh client. Only include stubs the component actually needs (`stubs.state()` only when the component reads from `~/state`). Import from `test/stubs`.

`stubs.reactRouter()` options: `path` (default `/`), `initialEntry` (the URL the stub starts at, defaults to `path`; a param route uses `path: '/items/:id'` with `initialEntry: '/items/1'`), `route` (`{action, clientAction, clientLoader, HydrateFallback, loader}`; the stub maps the client functions onto the stub route and refuses a server and client function of the same kind), `loader`, `action` (string storyId, `Record<Method, storyId>`, or full `ActionFunction`), `routes` (`{path, storyId}[]`, navigates to a story when the path loads), `actions` (`Record<path, ActionFunction>`, a per-path action that overrides the no-op entry for that path) and `destinations` (`string[]`, each path renders `Navigated to <path>` in a `main` so a play can assert arrival by text). Pass a function of the story context (`stubs.reactRouter(({args}) => ({...}))`) to read `fn()` spies from args. `actions` keys must differ from `path`: the main route matches first, so an action keyed to it never fires; observe a form posting to its own route through `action`.

A story file has exactly one `stubs.reactRouter` decorator, at meta level, because a nested Router throws. Vary the router per story through the function form, never a second decorator.

```tsx
decorators: [
  stubs.reactRouter({
    action: 'my-story--other-state',
    path: '/things',
    routes: [{path: '/things/1', storyId: 'my-story--detail'}],
  }),
],
```

## Padding / layout

Layout is `fullscreen`. Use `parameters.wrap: 'p-4'` for padding instead of wrapper divs in JSX.

## Story variant naming

| Variant name        | When to use                                    |
| ------------------- | ---------------------------------------------- |
| `Default`           | The primary/happy-path render (always present) |
| `Loading`           | Component in loading/pending state             |
| `Disabled`          | Component in disabled state                    |
| `WithError`         | Component showing a validation or server error |
| `NoItems` / `Empty` | Empty-state variant                            |
| `LongStrings`       | Overflow / wrapping stress test                |

## Dark-mode and Chromatic

Chromatic snapshots every story in a `light` and a `dark` mode (`.storybook/modes.ts`, both at 1280px), no per-story setup needed. Override a mode by its key in story-level parameters:

```tsx
parameters: {
  chromatic: {
    disableSnapshot: true,                // non-deterministic stories (spinners, env-injected data)
    modes: {
      dark: {disable: true},              // light-only snapshot
      // or a different width for both themes:
      // dark: {viewport: 375}, light: {viewport: 375},
    },
  },
},
```

Never set `chromatic.viewports`: Chromatic rejects it alongside modes.

## i18n in stories

i18n is global, no setup needed. Use `useTranslation()` inside the story function to vary content by locale (`i18n.language`).

## Test data

`msw-storybook-addon` is wired in `.storybook/preview.ts`; a story supplies request handlers through `parameters.msw.handlers`. `@msw/data` collections from `test/mocks/database` stay usable for seed data. Reads on a `Collection` are sync, so stories can call them inline:

```tsx
import database from 'test/mocks/database';
import {toCamelCase} from '~/utils/object';

export const Default: StoryFn = () => {
  const things = database.things.findMany(undefined).map(toCamelCase) as Things;
  return <ThingsGrid things={things} />;
};
```
