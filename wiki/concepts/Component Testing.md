---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [concept, testing]
---

# Component Testing

## A story with a play is the test

A component test is a story whose `play` function asserts the behavior. Vitest runs it in headless Chromium through `@storybook/addon-vitest`, so the story's decorators, stubs, mocked context and i18n are the test's setup and nothing re-derives them in a second file. There is no `.test.tsx` beside a component's stories and no standalone `render()`. Assertions use `expect`, `fn`, `userEvent`, `waitFor` and `within` from `storybook/test`. One story covers one behavior, named for it. See [[Stories as Tests]] for the model and the harness rules, and `frontend/.claude/rules/storybook.md` for authoring.

```tsx
export const ShowsError: Story = {
  play: async ({canvasElement}) => {
    await expect(
      await within(canvasElement).findByRole('alert')
    ).toHaveTextContent('Required');
  },
};
```

## Stubs, never framework mocks

> [!warning] Never manually mock framework deps
> Don't mock `react-router`, `react-i18next`, or other framework deps. Use the stubs in `frontend/test/stubs/` instead; they wire real providers with sensible defaults.

`frontend/test/stubs/` exposes `stubs.reactRouter()`, `stubs.state()`, etc. Apply as decorators in the component's story file under `tests/`; the same decorators serve Storybook, Chromatic and the Vitest run. Only mock **external services** or **utilities** the component imports directly.

## Spying on a callback

A play that asserts a callback ran needs the spy to reach the real component. Declare the spy as an arg (`fn()`) and pass it into the rendered component from the story's `render` or template, spreading `{...args}` **last**, after any hardcoded default. A story that hardcodes the callback, or spreads `{...args}` before it, silently drops the spy. The assertion still runs, it just proves nothing: `not.toHaveBeenCalled()` passes vacuously with the callback never wired, so the story stays green even if the behavior it guards is broken.

```tsx
// GOOD - accepts args and spreads {...args} LAST, so the fn() spy reaches onChange
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" onChange={() => {}} {...args} />
);
```

```tsx
// BAD - hardcodes onChange after the spread (or never accepts args), so the spy is dropped
const Template: StoryFn = (args) => (
  <Toggle label="Notifications" {...args} onChange={() => {}} />
);
```

## Custom Conform inputs

Stateful custom form components MUST use `useInputControl` to stay in sync with Conform validation state. Local `useState` desyncs once validation fails. See [[Form Components]] § warning.

## Reference example

`frontend/app/components/form/tests/composed-form.tsx`: a Conform form composed from ui `Field` parts, with its stories, whose play functions are the integration tests.

For the current file pattern (where stories and hook tests go), Serena and the scaffolders (`/new-component`, `/new-route`) handle it; query Serena rather than maintaining the layout here.

## Accessibility assertions

`@storybook/addon-a11y` axe-checks every story with no assertion written, so a render-only story is already an accessibility test. A page story adds play assertions for one level-1 heading and a `main` landmark, because addon-a11y scopes axe to the body. See [[Accessibility]].
