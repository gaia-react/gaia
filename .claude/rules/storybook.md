---
paths:
  - 'app/**/*.stories.tsx'
  - '.storybook/**/*'
---

# Storybook Conventions

The `/new-component` command scaffolds the canonical story shape. This rule covers what to do when authoring or extending a story beyond that scaffold.

## When to write a story

Write a story for every component scaffolded with `/new-component`. Skip stories only for pure-utility components with no visual output (e.g. context providers, HOCs with no markup).

## File location

Stories live in the component's `tests/` subfolder as `index.stories.tsx`.

## Typing

Use `Meta` and `StoryFn` from `@storybook/react-vite`. Never use `Story` (deprecated alias).

## Title convention

Slash-separated paths mirror the component's parent directory: `Components/MyComponent`, `Form/InputText`, `Components/Loaders/Spinner`.

## Decorator order

Apply stubs outermost → innermost: `state` then `reactRouter`. Only include stubs the component actually needs (`stubs.state()` only when the component reads from `~/state`). Import from `test/stubs`.

`stubs.reactRouter()` options: `path` (default `/`), `loader`, `action` (string storyId, `Record<Method, storyId>`, or full `ActionFunction`), and `routes` (`{path, storyId}[]`, navigates to a story when the path loads).

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

`ChromaticDecorator` renders light + dark side-by-side automatically, no per-story setup needed. Override via story-level parameters:

```tsx
parameters: {
  chromatic: {
    disableSnapshot: true,    // non-deterministic stories (spinners, env-injected data)
    excludeDark: true,        // light-only snapshot
    viewports: [1280, 412],   // override default [1280]
  },
},
```

## i18n in stories

i18n is global, no setup needed. Use `useTranslation()` inside the story function to vary content by locale (`i18n.language`).

## Test data

No `msw-storybook-addon` is configured. Pull seed data from the `@msw/data` collections via `test/mocks/database`. Reads on a `Collection` are sync, so stories can call them inline:

```tsx
import database from 'test/mocks/database';
import {toCamelCase} from '~/utils/object';

export const Default: StoryFn = () => {
  const things = database.things.findMany(undefined).map(toCamelCase) as Things;
  return <ThingsGrid things={things} />;
};
```
