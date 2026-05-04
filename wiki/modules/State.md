---
type: module
path: app/state/
status: active
language: typescript
purpose: Global React Context+Provider state
created: 2026-04-20
updated: 2026-05-04
tags: [module, state]
---

# State

GAIA uses plain React Context+Provider for global state — no Redux, Zustand, etc. The barrel `app/state/index.tsx` composes all providers into a single `<State>` component consumed by `root.tsx`.

## Template ships with no slices

The template ships with **no global state slices** — `<State>` is currently a passthrough. It exists as the established hook point so consumers can register their own providers (auth, feature flags, etc.) without touching `root.tsx`.

> [!key-insight] Theme is loader-derived, not state
> Theme is **not** a state slice. It's derived in the loader on every render from a cookie + `Sec-CH-Prefers-Color-Scheme` client hint, so no React state is required. See [[Theme Flow]] and [[Dark Mode Modernization]].

## Canonical pattern

Every state slice in `app/state/` follows one of two variants — full implementations are in the `state-pattern` rule (`.claude/rules/state-pattern.md`).

**Read-only** (value from SSR loader, components only read):
Context holds `Maybe<T>`; hook asserts non-null and returns `T`. Optional `useMaybeX()` variant returns `Maybe<T>` without throwing.

**Editable** (client-side mutation needed):
Context holds `[value, setter]` tuple (same shape as `useState`); use `noop` from `~/utils/function` as the default setter.

```tsx
const XContext = createContext<XContextValue>([undefined, noop]);
export const XProvider: FC<XProviderProps> = ({children, initialState}) => {
  const value = useState(initialState);
  return <XContext.Provider value={value}>{children}</XContext.Provider>;
};
XProvider.displayName = 'XProvider';
```

## Naming conventions

- Provider: `XProvider`
- Required hook: `useX()` — throws outside Provider
- Optional hook: `useMaybeX()` — returns `Maybe<T>`, no throw
- Context: `XContext` — **never exported**

## When NOT to use Context

- **Component-local state** → `useState`
- **Filter / sort / pagination** → URL search params (`useSearchParams`) — bookmarkable and shareable
- **Server data without client mutation** → loader data via `useLoaderData` directly

## Initial state from the loader

Providers receive SSR-safe initial state from `root.tsx` loader data, preventing hydration mismatches. Query Serena to read the live `AppWithState` implementation in `app/root.tsx`.

## See also

- `state-pattern` rule (`.claude/rules/state-pattern.md`) — prescriptive rule (naming, typing, colocation)
- [[Theme Flow]] — full SSR→client theme lifecycle
