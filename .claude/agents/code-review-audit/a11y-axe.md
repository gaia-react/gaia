---
subagents: [react-patterns]
library: 'axe-core + @axe-core/playwright'
---

# Accessibility (axe) Audit Rules

These rules layer on top of `.claude/rules/accessibility.md` (already enforced by the react-patterns subagent) — do not re-list patterns from that rule. Flag only the runtime/scaffolding gates and static patterns below.

## Test coverage gate (Important)

Every changed file matching `app/components/*/tests/index.test.tsx` must contain at least one call to `expectNoA11yViolations` (imported from `test/a11y`). New component tests without an axe assertion are flagged Important — the runtime layer is the only catcher for color-contrast, ARIA-allowed-attr, and dynamic landmark issues.

```tsx
// BAD — no axe assertion in a new component test
import {render, screen} from '@testing-library/react';
test('renders', () => {
  render(<MyButton>Save</MyButton>);
  expect(screen.getByRole('button')).toBeInTheDocument();
});

// GOOD
import {render, screen} from '@testing-library/react';
import {expectNoA11yViolations} from 'test/a11y';
test('renders', async () => {
  const {container} = render(<MyButton>Save</MyButton>);
  expect(screen.getByRole('button')).toBeInTheDocument();
  await expectNoA11yViolations(container);
});
```

## jsdom opt-in gate (Critical)

Every test file calling `expectNoA11yViolations` must have `// @vitest-environment jsdom` as its first line. axe-core mutates `Node.prototype.isConnected`, which happy-dom's getter-only implementation rejects with `TypeError: Cannot set property isConnected`. The throw surfaces only the first time axe runs against the prototype in a given worker, so it can pass locally and fail in CI. Flag missing as Critical.

```tsx
// BAD — defaults to happy-dom, axe throws at runtime
import {expectNoA11yViolations} from 'test/a11y';

// GOOD
// @vitest-environment jsdom
import {expectNoA11yViolations} from 'test/a11y';
```

## Static a11y patterns (additions only)

Patterns the eslint plugin and `.claude/rules/accessibility.md` do not cover:

- **Heading order across siblings** — `<h1>` followed directly by `<h3>` (or any 2+ level skip) inside the same render tree fails axe `heading-order`. Flag and recommend reducing the gap or adding the missing intermediate level.
- **Landmark uniqueness** — exactly one `<main>` per page. Flag any `<main>` inside a component under `app/components/` that is likely composed into a page already wrapping its slot in `<main>`. Recommend `<section>` or `<div>` and let the page own the landmark.
- **Decorative `<img>` without explicit `alt=""`** — `eslint-plugin-jsx-a11y` allows omission; axe flags `image-alt`. Force explicit `alt=""` on decorative images so intent is unambiguous.
- **Icon-only `<button>` without `aria-label`** — heuristic: a `<button>` whose only child is an import from `react-icons` or a component matching `*Icon`. Flag axe `button-name` risk and require `aria-label`.

```tsx
// BAD
<button onClick={handleClickClose}><CloseIcon /></button>

// GOOD
<button aria-label={t('close')} onClick={handleClickClose}><CloseIcon /></button>
```

## Action on output

When violations surface, recommend the user invoke the `a11y-fixes` skill (`.claude/skills/a11y-fixes/SKILL.md`) for the per-rule playbook. Cross-reference `.claude/rules/accessibility.md` for the underlying conventions.
