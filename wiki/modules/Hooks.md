---
type: module
path: frontend/app/hooks/
status: active
language: typescript
purpose: Global custom React hooks
created: 2026-04-20
updated: 2026-10-05
tags: [module, hooks]
---

# Hooks

Global custom hooks live in `frontend/app/hooks/`. Component-specific hooks live in each component or page folder's own `hooks/` folder. A few context-bound hooks co-locate with their provider under `frontend/app/utils/` instead (`useNonce` in `nonce.ts`, `useRequestInfo`/`useOptionalRequestInfo` in `request-info.ts`).

## Lift rule

A hook starts in the component that needs it. When a second component needs the same logic, lift it to the lowest shared ancestor's `hooks/` folder. Only lift to `frontend/app/hooks/` when the hook is genuinely cross-cutting (breakpoint, viewport, timing primitives).

## Conventions

Named export, `use` prefix, one hook per file, tests in `frontend/app/hooks/tests/`. Use `/new-hook` to scaffold. File names and the layout are owned by `frontend/.claude/rules/coding-guidelines-react.md`; see [[Coding Guidelines]] for the general naming rules.

For the current bundled inventory and signatures, query Serena (`.claude/rules/code-search.md`).

See the `react-code` skill (`frontend/.claude/skills/react-code/SKILL.md`) for `useEffect` and `useState` rules, and its `## Memoization: compiler-first` section for memoization.
