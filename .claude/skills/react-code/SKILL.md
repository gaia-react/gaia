---
name: react-code
description: Patterns and conventions for writing and editing React code, including components and hooks. Use this skill whenever writing or reviewing React components, hooks (useEffect, useCallback, useState), event handlers, or component extraction decisions. Also trigger when debugging stale closures, infinite re-renders, or unnecessary re-renders caused by memoization issues, or when deciding whether to add a dependency, reach for a web-platform API (Intl, URL, crypto.randomUUID), or hand-roll a primitive. Also trigger when choosing a React 19 idiom, deciding between forwardRef and ref-as-prop, useContext and use(), or Context.Provider and the Context shorthand; when conditional rendering risks the && numeric-0 leak; or when tempted to reach for React's form Actions (useActionState, useFormStatus, useOptimistic) instead of React Router's form handling.
---

# React Code

Write and edit React components, pages, routes, hooks, and forms following project conventions.

## Reach for the Platform First

Before installing a package or hand-rolling a primitive, walk this ladder and stop at the first hit:

1. **Existing GAIA code**, a component, hook, or util already covers it (form inputs → Gate 2).
2. **Web platform**, a browser API or native element does the job: `Intl` (dates, numbers, lists, plurals), `URL` / `URLSearchParams`, `crypto.randomUUID()`, `structuredClone()`, `AbortController`, native `Array` / `Object` methods, `<dialog>`, modern CSS (`:has()`, container queries).
3. **Already-installed dependency**, check `package.json` before adding a sibling that does the same job. For component/hook traps Claude often hand-rolls (client-only/useHydrated, sse, debounce-fetcher), see the remix-utils decision map at `wiki/dependencies/remix-utils.md` before reinventing.
4. **New dependency**, only when 1-3 genuinely fall short; the added weight has to earn its place.
5. **Custom code**, last resort, kept minimal.

The largest real savings come from `Intl` over date/number-formatting libraries and native collection methods over `lodash`/`underscore` (already enforced by `you-dont-need-lodash-underscore`). Reaching for the platform replaces a needless dependency or bespoke widget; it never overrides accessibility, input validation, or an existing GAIA component (a wrapper exists for a reason).

## Pre-Flight Gates

Most hook bugs come from misidentifying the type of problem being solved. Before writing or editing hooks, run through these gate, it only applies when the relevant pattern is present in your changes.

### Gate 1: Hook Check

**Before writing `useEffect`:**

1. Can I calculate this during render? → Derive inline or `useMemo`, no Effect needed.
2. Does this respond to a user action? → Put it in the event handler, no Effect needed.
3. Am I syncing state to other state? → Derive it; remove the redundant state, no Effect needed.
4. Am I notifying a parent of a state change? → Call both setters in the handler, no Effect needed.
5. Do I need to reset child state when a prop changes? → Use `key`, no Effect needed.
6. Am I synchronizing with an external system (browser API, third-party widget, network)? → Effect is appropriate here. Add cleanup. For data fetching, include an `ignore` flag.

**Before writing `useCallback`:**

Only use when the function is:

1. Passed as a prop to a `memo`-wrapped component
2. A dependency of `useEffect`, `useMemo`, or another `useCallback`
3. Passed to a child that uses it in a hook dependency array

If none apply, skip `useCallback`, it adds indirection without benefit.

**`useState` type inference:** Omit explicit type when inferable from the default value. Add types for unions or complex objects. For an absent initial value, prefer `undefined` over `null` (GAIA never-null): `useState<T>()` is already typed `T | undefined`.

### Gate 2: Form Element Check

**Before writing `<input>`, `<select>`, `<textarea>`, or `<input type="checkbox">`:**

| Native element                         | Use instead                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------- |
| `<input type="text">`                  | `InputText` (`~/components/Form/InputText`)                                     |
| `<input type="email">`                 | `InputEmail` (`~/components/Form/InputEmail`)                                   |
| `<input type="password">`              | `InputPassword` (`~/components/Form/InputPassword`)                             |
| `<input type="checkbox">` (single)     | `Checkbox` (`~/components/Form/Checkbox`)                                       |
| `<input type="checkbox">` (group)      | `Checkboxes` (`~/components/Form/Checkboxes`), needs `options: Option[]`        |
| `<input type="radio">` / radio group   | `RadioButtons` (`~/components/Form/RadioButtons`), needs `options: Option[]`    |
| `<select>`                             | `Select` (`~/components/Form/Select`), needs `name` + `options: SelectOption[]` |
| `<textarea>`                           | `TextArea` (`~/components/Form/TextArea`), needs `name`; auto-resizes           |
| Date (year/month/day)                  | `YearMonthDay` (`~/components/Form/YearMonthDay`)                               |
| Field with label + error + description | `Field` (`~/components/Form/Field`)                                             |

**Exceptions (native OK):** `<input type="hidden">`, `<input type="file">`, `<input type="range">`.

`Select` requires `options: SelectOption[]` (`{label, value}`). Build this array (with `useMemo` if derived from translations/data) rather than inline `<option>` elements.

**CRITICAL, `@conform-to/zod`:** Always import from `/v4` subpath. The default export targets Zod v3 and causes a runtime error that typecheck/lint/build do NOT catch.

```tsx
// BAD, runtime error
import {parseWithZod} from '@conform-to/zod';
// GOOD
import {parseWithZod} from '@conform-to/zod/v4';
```

See `references/conform-forms.md` for full Conform + Zod wiring. Beyond the import path, all Zod schemas use Zod 4 syntax, the typescript skill's `references/zod.md` is the canonical Zod 3 → Zod 4 migration map (`z.strictObject`, top-level string formats, etc.).

### Gate 3: Translation Check

**Before writing ANY user-visible string in JSX:**

Every string a user can see or hear, labels, headings, placeholders, button text, error messages, tooltips, descriptions, status text, `aria-label` attributes, `alt` text, and `title` attributes, must come from a `t()` call. Hard-coded English strings in JSX are bugs. This applies to new components, new UI sections, and modifications that add visible text. The only exceptions are punctuation-only strings, single-character symbols, developer-facing content (console.log, comments, test assertions), and approximate skeleton-loader placeholder text standing in for a dynamic runtime value. Skeleton text that mirrors static `t()` content must still use `t()` (see the skeleton-loaders skill).

1. Add the translation key to the appropriate namespace file in `app/languages/en/` (and any other locale folders present, copying the English string verbatim as a placeholder)
2. Use `t('key')` in the component, never a string literal
3. **One `useTranslation()` per component**: never multiple calls for different namespaces
4. Use `{ns: 'other'}` as second arg to `t()` for cross-namespace access
5. Choose the most-used namespace for `useTranslation()` to minimize overrides
6. **Before adding a new key:** search `app/languages/en/` for existing equivalent strings
7. Dynamic keys: ensure interpolated values have literal union types, not `string`

See `references/translation-patterns.md` for edge cases (keyPrefix, Trans component, dedup).

### Gate 4: React 19 Idiom Check

GAIA writes React 19 idioms. The work here is to not regress to pre-19 habits, and to not pull in React's framework-level form APIs that React Router already owns.

**Before writing `forwardRef`: don't.** In React 19, `ref` is an ordinary prop on function components, so `forwardRef` is no longer needed (slated for deprecation in a future release). GAIA has zero `forwardRef`; every Form control destructures `ref` from props. Match that.

```tsx
// BAD, needless indirection
const InputText = forwardRef<HTMLInputElement, Props>((props, ref) => <input ref={ref} {...props} />);
// GOOD, ref is just a prop
const InputText: FC<Props> = ({ref, ...rest}) => <input ref={ref} {...rest} />;
```

The ref _type_ (`Ref<T>`, or `ComponentProps<'input'>` already carrying `ref`) is the typescript skill's domain.

**Before writing `&&` in JSX, make the left operand a real boolean.** `&&` returns its left operand when falsy. `false`/`null`/`undefined` render nothing, but a numeric **`0`** is a renderable value and leaks the literal "0" into the DOM. This is the most common React rendering bug. **Lint catches the `.length && <JSX/>` form** (via `no-restricted-syntax`), but the general `count && <X/>` case still slips through, so make the left operand a real boolean yourself.

```tsx
// BAD, renders "0" when the list is empty
{items.length && <List items={items} />}
// GOOD, force a real boolean
{items.length > 0 && <List items={items} />}
```

For render-or-nothing, a boolean-guarded `&&` is the idiom; it replaces the old `cond ? <X/> : null`. A ternary is only for a genuine either/or where both arms render, never `: null`.

**Before writing `useContext` or `<Context.Provider>`, use the React 19 forms.** Read context with `use()` (unlike `useContext`, it may be called conditionally or after an early return); render the context object directly as the provider.

```tsx
const nonce = use(NonceContext); // not useContext(NonceContext)
<NonceContext value={nonce}>{children}</NonceContext>; // not <NonceContext.Provider>
```

`<Context.Provider>`/`<Context.Consumer>` are legacy (deprecation planned). GAIA uses the `<Context>` shorthand and `use()` exclusively, never `.Provider`, `.Consumer`, or `useContext`. Convert any you find.

**Stay in React Router's lane; don't reach for React's form Actions.** GAIA submits through React Router `<Form>` / `useFetcher` + route `action` exports, validates with Conform + Zod (Gate 2), and reads pending/optimistic state from React Router. React 19's framework-level form hooks duplicate and fight that surface. When tempted, redirect:

| React 19 API (don't use here)          | Use instead                                                                                   |
| -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `useActionState`, `<form action={fn}>` | route `action` + `useActionData`                                                              |
| `useFormStatus`                        | `useNavigation().state` / `fetcher.state`                                                     |
| `useOptimistic`                        | fetcher-based optimism (`useOptimisticThemeMode` in `useTheme.ts`)                            |
| `use(promise)` for route data          | loader + `useLoaderData` (`use(promise)` only for non-route promises inside `<Suspense>`)     |

Metadata is the mirror case: GAIA renders `<title>`/`<meta>` as JSX (React 19 hoisting), not a React Router route `meta`/`links` export. Keep it that way; adding a route `meta` export to a page that already renders `<title>` in JSX produces duplicate tags.

When you do reach for React Router's API, read it from the version-matched docs shipped at `node_modules/react-router/docs`, not the web.

Rendering nothing from a `return` is enforced by `@gaia-react/lint`'s `no-null-render` rule (autofix); a `: null` ternary arm is caught by `no-restricted-syntax` (report-only). No manual rewrite needed.

For `useEffectEvent` (the sanctioned replacement for stale-deps / latest-ref hacks) and ref-callback cleanup functions, see `references/hook-patterns.md`.

## Component Structure

- **FC typing:** `const MyComponent: FC<Props> = ({...}) => ...`
- **One component per file**: keeps co-location clean and makes code-splitting predictable
- **Named React imports:** `import {useState} from 'react'`, never `React.useState()`, avoids the React namespace and makes tree-shaking explicit
- **Type imports:** `import type {ChangeEventHandler} from 'react'`, never `React.FC`
- **Event handler types:** Prefer `ChangeEventHandler<HTMLInputElement>` over inline event typing
- **Event handler naming:** `handle{Action}{Element}`, the `{Element}` is required so the name says _what it does_, not just _when it fires_; e.g. `handleClickSave`, `handleChangeInput`, `handleCopyStack`. A bare event name (`handleClick`, `handleChange`, `handleSubmit`) trips `react-doctor/no-generic-handler-names`.

### Component Extraction

Extract when a section meets **all** criteria:

1. Self-contained (own state/fetcher, or pure display with no shared state)
2. Clear boundary (visible UI section with small props interface)
3. ~60+ lines of JSX/logic

**Do not extract** when state/refs are shared across sections, extraction needs 5+ props/callbacks, section is under ~60 lines, or form validation is tightly coupled.

How: Create `ParentComponent/NewSection/index.tsx`, move exclusive types/state/handlers/JSX, define minimal `Props` type.

## Route-Page Architecture

### Route files (`app/routes/`)

Thin shell only:

- `loader` / `action` functions
- Zod schemas for the action
- One-line default export: `const MyRoute: FC = () => <MyPage />;`

**No UI code, hooks, state, or sub-components in route files.** Metadata renders as JSX (`<title>`/`<meta>`) in the page, not a route `meta` export (Gate 4).

### Page components (`app/pages/`)

```
app/pages/{Group}/{PascalName}Page/index.tsx                    # most pages
app/pages/{Group}/{Section}/{PascalName}Page/index.tsx          # only when a section grouping is needed
```

For loader data: use `useLoaderData<typeof loader>()` (import the `loader` type from the route file) or `useLoaderData<LoaderData>()` (import `LoaderData` from a sibling `types.ts`). Never define the type inline in the page component file itself.

Sub-components go in sibling folders. Tests/stories in `{PageName}/tests/`.

When stories need different loader data, put `stubs.reactRouter()` decorators on individual stories (not meta) to avoid nested Router errors with `composeStory`.

## References

- `references/hook-patterns.md`, Read when writing any Effect or useCallback, or when debugging stale closures, double-firing effects, or infinite re-renders.
- `references/conform-forms.md`, full Conform + Zod form wiring walkthrough
- `references/translation-patterns.md`, i18n edge cases, Trans component, dedup rules
