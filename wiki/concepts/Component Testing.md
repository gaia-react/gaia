---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-04
tags: [concept, testing]
---

# Component Testing

## Why `composeStory` is mandatory

Component tests use Storybook stories with `composeStory`, never standalone `render()` calls. The reason: stories already encode the setup the component needs (decorators, stubs, mocked context, i18n). Re-deriving that setup inside a `.test.tsx` file duplicates the wiring and lets the two drift. Visual regression (Chromatic) and integration tests share one source of truth.

```tsx
const MyComponent = composeStory(Default, Meta);
render(<MyComponent />);
expect(screen.getByText('Hello')).toBeInTheDocument();
```

## Stubs, never framework mocks

> [!warning] Never manually mock framework deps
> Don't mock `react-router`, `react-i18next`, or other framework deps. Use the stubs in `frontend/test/stubs/` instead; they wire real providers with sensible defaults.

`frontend/test/stubs/` exposes `stubs.reactRouter()`, `stubs.state()`, etc. Apply as decorators in the component's story file under `tests/`; the stories pull them in for both Storybook and Vitest. Only mock **external services** or **utilities** the component imports directly.

## Overriding a prop (callback spies)

A test overriding a prop on a composed story, especially a callback it spies on, only reaches the real component if the story accepts `(args)` and spreads `{...args}` **last**, after any hardcoded default. GAIA's stories hardcode structural/demo props inline and spread `{...args}` only for the controllable knobs, so ordering is load-bearing: a story that hardcodes the callback, or spreads `{...args}` before it, silently drops a render-time override. A spy assertion against a dropped override still runs, it just proves nothing: `not.toHaveBeenCalled()` passes vacuously with the callback never wired, so the test stays green even if the behavior it's meant to guard is broken.

```tsx
// GOOD - accepts args and spreads {...args} LAST, so a test can override onChange
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" onChange={() => {}} {...args} />
);
```

```tsx
// BAD - hardcodes onChange after the spread (or never accepts args), so a render-time override is dropped
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" {...args} onChange={() => {}} />
);
```

## Custom Conform inputs

Stateful custom form components MUST use `useInputControl` to stay in sync with Conform validation state. Local `useState` desyncs once validation fails. See [[Form Components]] § warning.

## Reference example

`frontend/app/components/form/tests/composed-form.tsx`: a Conform form composed from ui `Field` parts, with its story and a `composeStory`-driven integration test beside it.

For the current file pattern (where to put `.stories.tsx` vs `.test.tsx`), Serena and the scaffolders (`/new-component`, `/new-route`) handle it; query Serena rather than maintaining the layout here.

## Accessibility assertions

`frontend/test/a11y.ts` exports `expectNoA11yViolations(container, options?)` and `runAxe(container, options?)`, thin wrappers around `axe-core` that fail a test on any WCAG-relevant violation. The scaffolder injects an `a11y` block into every new component test by default. The helper requires the `jsdom` runtime: tests calling it must declare `// @vitest-environment jsdom` as the very first line of the file. The global env stays `happy-dom` for speed; the per-file opt-in exists because `axe-core` mutates `Node.prototype.isConnected`, which `happy-dom` defines as a getter-only property. The helper throws a clear setup error when the env is wrong, so a missing directive surfaces immediately.
