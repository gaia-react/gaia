---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
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
> Don't mock `react-router`, `react-i18next`, or other framework deps. Use the stubs in `test/stubs/` instead; they wire real providers with sensible defaults.

`test/stubs/` exposes `stubs.reactRouter()`, `stubs.state()`, etc. Apply as decorators in `tests/index.stories.tsx`; the stories pull them in for both Storybook and Vitest. Only mock **external services** or **utilities** the component imports directly.

## Custom Conform inputs

Stateful custom form components MUST use `useInputControl` to stay in sync with Conform validation state. Local `useState` desyncs once validation fails. See [[Form Components]] § warning.

## Reference example

`app/components/Form/YearMonthDay/tests/`: a parent-controlled composite of three Selects plus a hidden input that mirrors the ISO date value for Conform. The story wires it into a Conform form with `useInputControl`; `composeStory` then drives the integration test.

For the current file pattern (where to put `.stories.tsx` vs `.test.tsx`), Serena and the scaffolders (`/new-component`, `/new-route`) handle it; query Serena rather than maintaining the layout here.

## Accessibility assertions

`test/a11y.ts` exports `expectNoA11yViolations(container, options?)` and `runAxe(container, options?)`, thin wrappers around `axe-core` that fail a test on any WCAG-relevant violation. The scaffolder injects an `a11y` block into every new component test by default. The helper requires the `jsdom` runtime: tests calling it must declare `// @vitest-environment jsdom` as the very first line of the file. The global env stays `happy-dom` for speed; the per-file opt-in exists because `axe-core` mutates `Node.prototype.isConnected`, which `happy-dom` defines as a getter-only property. The helper throws a clear setup error when the env is wrong, so a missing directive surfaces immediately.
