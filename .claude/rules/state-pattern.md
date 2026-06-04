---
paths:
  - 'app/state/**/*'
---

# State Pattern

Applies to `app/state/**`. All React Context creation lives there by convention.

## When to Use Context

- **Context**: cross-tree global state (theme, async data from loader)
- **`useState`**: component-local or lifted state that doesn't need tree-wide access
- **URL state** (`useSearchParams`): filter/sort/pagination, shareable, bookmarkable

## File Location

Each state slice lives in `app/state/{name}.tsx`. The barrel `app/state/index.tsx` composes all providers.

## Naming Conventions

| Piece               | Convention                            | Example               |
| ------------------- | ------------------------------------- | --------------------- |
| Provider component  | `XProvider`                           | `ThingsProvider`      |
| Required read hook  | `useX()`, throws if outside Provider | `useThings()`         |
| Optional read hook  | `useMaybeX()`, returns `Maybe<T>`    | `useMaybeThings()`    |
| Context variable    | `XContext` (unexported)               | `ThingsContext`       |
| Context type        | `XContextValue`                       | `ThingsContextValue`  |
| Provider props type | `XProviderProps`                      | `ThingsProviderProps` |

## Two Variants

### Read-only (async/loader data)

Context holds `Maybe<T>`; hook asserts non-null and returns `T`.

```tsx
const ThingsContext = createContext<Maybe<Things>>(undefined);

export const useThings = (): Things => {
  const context = useContext(ThingsContext) as Maybe<Things>;
  if (!context)
    throw new Error('useThings must be used within a ThingsProvider');
  return context;
};

export const ThingsProvider: FC<ThingsProviderProps> = ({children, things}) => (
  <ThingsContext.Provider value={things}>{children}</ThingsContext.Provider>
);
ThingsProvider.displayName = 'ThingsProvider';
```

### Editable (useState tuple)

Context holds `[value, setter]`; use `noop` as default setter.

```tsx
import {noop} from '~/utils/function';

type XContextValue = [Maybe<number>, Dispatch<SetStateAction<Maybe<number>>>];
const XContext = createContext<XContextValue>([undefined, noop]);

export const useX = () => {
  const context = useContext(XContext) as Maybe<XContextValue>;
  if (!context) throw new Error('useX must be used within an XProvider');
  return context;
};

export const XProvider: FC<XProviderProps> = ({children, initialState}) => {
  const value = useState(initialState);
  return <XContext.Provider value={value}>{children}</XContext.Provider>;
};
XProvider.displayName = 'XProvider';
```

## Rules

- **Never export the Context**: only export the Provider and hook(s)
- **Always set `displayName`** on the Provider component
- **Always throw** in `useX()` when called outside the Provider
- **`useMaybeX()`** (no throw) is appropriate when the value is genuinely optional (e.g., `useUser` vs `useMaybeUser`)
- **`initialState` prop** passes SSR loader data into the Provider; avoids hydration mismatches
- Providers are composed in `app/state/index.tsx`, register new ones there
- Do not reach into `app/state/` from outside `app/`, consumers import the hook only
