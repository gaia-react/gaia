---
type: module
path: app/state/
status: active
language: typescript
purpose: Global React Context+Provider state
created: 2026-04-20
updated: 2026-04-26
tags: [module, state]
---

# State

GAIA uses plain React Context+Provider for global state — no Redux, Zustand, etc. The barrel `app/state/index.tsx` composes all providers into a single `<State>` component consumed by `root.tsx`.

## Bundled Providers

The template ships with **no global state slices** — `<State>` is currently a passthrough. It exists as the established hook point so consumers can register their own providers (auth, feature flags, etc.) without touching `root.tsx`.

Theme is not a state slice. It is derived in the loader on every render from a cookie + `Sec-CH-Prefers-Color-Scheme` client hint, so no React state is required. See [[Theme Flow]] and [[Dark Mode Modernization]].

## Canonical Pattern

Every state slice in `app/state/` follows one of two variants — full implementations are in the `state-pattern` rule (`.claude/rules/state-pattern.md`).

**Read-only** (value from SSR loader, components only read):
Context holds `Maybe<T>`; hook asserts non-null and returns `T`. Optional `useMaybeX()` variant returns `Maybe<T>` without throwing.

**Editable** (client-side mutation needed):
Context holds `[value, setter]` tuple (same shape as `useState`); use `noop` from `~/utils/function` as the default setter. Example:

```tsx
const XContext = createContext<XContextValue>([undefined, noop]);
export const XProvider: FC<XProviderProps> = ({children, initialState}) => {
  const value = useState(initialState);
  return <XContext.Provider value={value}>{children}</XContext.Provider>;
};
XProvider.displayName = 'XProvider';
```

## Naming Conventions

| Piece         | Convention                                   |
| ------------- | -------------------------------------------- |
| Provider      | `XProvider`                                  |
| Required hook | `useX()` — throws outside Provider           |
| Optional hook | `useMaybeX()` — returns `Maybe<T>`, no throw |
| Context       | `XContext` — **never exported**              |

## Initial State from the Loader

Providers receive SSR-safe initial state from `root.tsx` loader data, preventing hydration mismatches. See `app/root.tsx` for the live `AppWithState` implementation.

## When Not to Use Context

- **Component-local state** → `useState`
- **Filter / sort / pagination** → URL search params (`useSearchParams`) — bookmarkable and shareable
- **Server data without client mutation** → loader data via `useLoaderData` directly

## See Also

- `state-pattern` rule (`.claude/rules/state-pattern.md`) — prescriptive rule (naming, typing, colocation)
- [[Theme Flow]] — full SSR→client theme lifecycle
