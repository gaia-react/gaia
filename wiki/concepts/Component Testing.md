---
type: concept
status: active
created: 2026-04-20
updated: 2026-05-04
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
> Don't mock `react-router`, `react-i18next`, or other framework deps. Use the stubs in `test/stubs/` instead — they wire real providers with sensible defaults.

`test/stubs/` exposes `stubs.reactRouter()`, `stubs.state()`, etc. Apply as decorators in `tests/index.stories.tsx`; the stories pull them in for both Storybook and Vitest. Only mock **external services** or **utilities** the component imports directly.

## Custom Conform inputs

Stateful custom form components MUST use `useInputControl` to stay in sync with Conform validation state. Local `useState` desyncs once validation fails. See [[Form Components]] § warning.

## Reference example

`app/components/Form/YearMonthDay/tests/` — three Selects driven by a local hidden ISO date input, fully tested via `composeStory` and `useInputControl`.

For the current file pattern (where to put `.stories.tsx` vs `.test.tsx`), Serena and the scaffolders (`/new-component`, `/new-route`) handle it — query Serena rather than maintaining the layout here.
