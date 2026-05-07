---
name: eslint-fixes
description: Resolve specific ESLint errors and warnings that appear in this project. Use when fixing lint failures, ESLint reported issues, or autofix conflicts (e.g. no-void, canonical/export-specifier-newline vs prettier, no-shadow trailing underscores, sonarjs/deprecation, you-dont-need-lodash-underscore, testing-library/prefer-screen-queries, testing-library/await-async-events, jest-dom/prefer-*).
model: haiku
---

# ESLint Fix Patterns

How to resolve specific ESLint errors in this project.

## no-void

Don't use the `void` operator in event listener functions. Instead, make the function `async` and `await` the promise.

```tsx
// BAD
const handleClick = () => {
  void navigate('/path');
};

// GOOD
const handleClick = async () => {
  await navigate('/path');
};
```

## canonical/export-specifier-newline vs prettier conflict

Use inline `export const` declarations instead of a grouped `export { ... }` statement to avoid circular fix warnings between these two rules.

```tsx
// BAD — causes circular fix between prettier and canonical
export {DAYS, DURATIONS, FITNESS_GOALS};

// GOOD — declare with export directly
export const DAYS = ['mon', 'tue'] as const;
export const DURATIONS = [15, 30, 45] as const;
export const FITNESS_GOALS = ['weight_loss'] as const;
```

## no-shadow trailing underscores

ESLint's `no-shadow` autofixes by appending `_`. Once shadowing is resolved, remove the trailing `_`.

## sonarjs/deprecation

Never suppress with `eslint-disable`. Always fix the underlying deprecation.

Common case: Zod v4 deprecated `z.string().email()` in favor of `z.email()`.

```tsx
// BAD — suppressing the warning
// eslint-disable-next-line sonarjs/deprecation
email: z.string().email(),

// GOOD — use the non-deprecated API
email: z.email(),
```

## you-dont-need-lodash-underscore/\*

Use native JavaScript instead of lodash/underscore equivalents.

```tsx
// BAD
import _ from 'lodash';
const first = _.find(items, (item) => item.active);
const names = _.map(items, (item) => item.name);

// GOOD
const first = items.find((item) => item.active);
const names = items.map((item) => item.name);
```

## testing-library/prefer-screen-queries

Use `screen` queries instead of destructuring from `render()`.

```tsx
// BAD
const {getByText, getByRole} = render(<MyComponent />);

// GOOD
render(<MyComponent />);
screen.getByText('...');
screen.getByRole('button');
```

## testing-library/await-async-events

`userEvent` methods are async — always `await` them.

```tsx
// BAD
userEvent.click(button);

// GOOD
await userEvent.click(button);
```

## jest-dom/prefer-\*

Use jest-dom matchers instead of raw DOM property checks.

```tsx
// BAD
expect(input.value).toBe('hello');
expect(checkbox.checked).toBe(true);
expect(el.textContent).toBe('Hello');

// GOOD
expect(input).toHaveValue('hello');
expect(checkbox).toBeChecked();
expect(el).toHaveTextContent('Hello');
```
