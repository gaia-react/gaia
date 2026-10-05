---
subagents: [react-patterns, typescript, translation]
library: react-buckets
---

# React Bucket Audit Rules

Each section below belongs to one specialist subagent. Apply only the section naming your bucket and skip the others.

The house-style buckets below (hook gates, component structure and extraction, event-handler naming, inline props typing, named React imports) skip `components/ui/*.tsx`: that folder is vendored shadcn output that uses `function` declarations and `import * as React` by design (`frontend/.claude/rules/shadcn-ui.md`). Correctness findings (hooks bugs, accessibility, security) still apply there. `components/ui/tests/` is GAIA-authored and gets every bucket.

## React Patterns & Accessibility (react-patterns)

**From the react-code skill (`frontend/.claude/skills/react-code/SKILL.md`):**

Hook gates:

- Memoization (compiler-first; the rule and its two escape cases live in `frontend/.claude/skills/react-code/SKILL.md` `## Memoization: compiler-first`): flag a manual `useMemo`, `useCallback`, or `memo` that has no justifying comment naming one of the skill's two cases, and flag a `"use no memo"` directive that has no comment stating why. Each finding names the compiler-first rule and points to that skill section. Do NOT flag missing memoization, inline callbacks, inline object props, or unstable references passed to children: the compiler provides those. This is a house-style rule, so vendored `components/ui/*.tsx` (for example the `useMemo` in `components/ui/field.tsx`) stays exempt.
- `useEffect` anti-patterns: derived state in effects (derive inline during render), expensive calcs in effects (derive inline during render), user-event logic in effects (belongs in the handler), chained effects triggering each other, notifying parent of state changes via effect. Flag each with the correct alternative.
- State reset anti-pattern: `useEffect` that resets state when a prop changes, should use `key` instead.
- When `useEffect` is correct (external system sync, subscriptions), verify a cleanup function; for async data fetching inside an effect, verify an `ignore` flag guards the setter.
- `useState` type inference: omit explicit type when inferable from the default value. Only annotate for `null` initial values, unions, or complex objects.

Component structure:

- Inline props typing: components use `type MyComponentProps = {...}; const MyComponent = ({...}: MyComponentProps) => ...`, generics written `<T,>`; flag any `FC` or `FunctionComponent` import from `react`
- Named React imports: `import {useState} from 'react'`; never `React.useState()`; never import `FC` or `FunctionComponent`
- Type-only imports: `import type {ChangeEventHandler} from 'react'`
- Event handler typing: prefer `ChangeEventHandler<HTMLInputElement>` over inline `(e: ChangeEvent<HTMLInputElement>)`
- Event handler naming: `handle{Action}{Element}`, the `{Element}` is required; flag bare event names (`handleClick`, `handleChange`, `handleSubmit`), which trip `react-doctor/no-generic-handler-names`
- One component per file

Component extraction:

- Extract when a section meets all criteria: self-contained (own state/fetcher, or pure display), clear boundary with small props interface, ~60+ lines of JSX/logic
- Don't extract when state/refs are shared across sections, extraction needs 5+ props/callbacks, section is under ~60 lines, or form validation is tightly coupled

**From `frontend/.claude/rules/accessibility.md`:**

- Interactive elements reachable and operable via keyboard (Tab, Enter, Escape, Arrow keys); no keyboard traps
- Prefer semantic HTML (`<button>`, `<nav>`, `<main>`) over divs with ARIA roles
- `<img>` has descriptive `alt` or explicit `alt=""` for decorative images
- Color is never the sole indicator of meaning
- Modals/dialogs move focus on open, return focus to trigger on close
- `aria-live="polite"` for dynamic status updates (toasts); `aria-expanded`/`aria-controls` for disclosure widgets
- `aria-label` only when visible text is insufficient, don't duplicate visible text

## Route conventions (typescript)

**From `frontend/.claude/rules/routes.md`:**

- Route files (`app/routes/`) must be thin: only loader/action, meta (via loader), Zod schemas, and rendering the page component. No UI code, hooks, state, or sub-components.
- Page components live at `app/pages/<route path>/page.tsx` (layout rule: `frontend/.claude/rules/coding-guidelines-react.md`)
- Loader data: use `useLoaderData<typeof loader>()` (import the `loader` type from the route file) or `useLoaderData<LoaderData>()` (import `LoaderData` from a sibling `types.ts`). Never define the type inline in the page component file.
- Meta tags: set in the loader via server-side i18n (`getInstance(context)`), then render them in the route component or pass them to the page component, which renders them (the legal pages do this)
- Route files are flat dot-delimited files discovered by `@react-router/fs-routes`; group prefixes and their meanings are owned by `wiki/modules/Routing.md`. `actions.*` / `resources.*` files are no-UI data-endpoint routes with no page component: the lint carve-out only lets UI layers import their typed action/loader exports, and the no-UI-code rule above still applies to them.

## Translation (translation)

**From `frontend/.claude/rules/i18n.md`:**

- Every user-visible string in JSX, labels, headings, placeholders, button text, error messages, tooltips, status text, `aria-label`, `alt`, `title`, must come from a `t()` call. Flag hardcoded English strings. Exceptions: punctuation-only strings, single-character symbols, developer-facing content (console.log, comments, test assertions), and approximate skeleton-loader placeholder text standing in for a dynamic runtime value (skeleton text mirroring static `t()` content must still use `t()`).
