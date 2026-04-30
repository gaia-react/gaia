---
name: new-hook
description: Scaffold a new custom React hook with a test file.
---

Scaffold a new custom React hook with a test file.

## Step 1: Gather user input

Ask the user these questions using AskUserQuestion:

- Hook name (e.g. `useDebounce`, `useLocalStorage`) — will add `use` prefix if missing
- Brief description of what the hook does
- Parameters (name, type, and whether optional — e.g. `delay: number, callback: () => void`)
- Return type (e.g. `boolean`, `[value, setValue]`, `{data, isLoading, error}`)

## Step 2: Create hook file

Create `app/hooks/{hookName}.ts` following the useBreakpoint/useTimeout patterns:

```ts
import {useEffect, useState} from 'react';

export const {
  hookName,
} = ({params}): {returnType} => {
  // implementation based on description
};
```

Key conventions from the reference hooks:

- Named export (not default)
- Import only needed React hooks
- Use `useRef` for mutable values that shouldn't trigger re-renders (timers, previous values)
- Clean up side effects in `useEffect` return
- Type parameters explicitly

## Step 3: Create test file

Create `app/hooks/tests/{hookName}.test.ts`:

```ts
import {renderHook, act} from '@testing-library/react';
import {describe, expect, test} from 'vitest';
import {{hookName}} from '../{hookName}';

describe('{hookName}', () => {
  test('returns initial value', () => {
    const {result} = renderHook(() => {hookName}({defaultParams}));
    expect(result.current).toBe({expectedInitialValue});
  });

  test('updates on change', () => {
    // test the hook's behavior
  });
});
```

- Use `renderHook` from `@testing-library/react`
- Use `act` when testing state changes
- Use `vi.useFakeTimers()` / `vi.advanceTimersByTime()` for time-dependent hooks
- Test edge cases (unmount cleanup, parameter changes, etc.)

## Step 4: Verify

Run these commands sequentially, stopping if any fails:

```bash
pnpm typecheck && pnpm lint && pnpm test --run
```

Fix any issues before reporting to the user.
