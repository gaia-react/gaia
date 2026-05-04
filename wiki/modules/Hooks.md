---
type: module
path: app/hooks/
status: active
language: typescript
purpose: Global custom React hooks
created: 2026-04-20
updated: 2026-05-04
tags: [module, hooks]
---

# Hooks

Global custom hooks live in `app/hooks/`. Component-specific hooks live in `app/components/{Name}/hooks/`.

## Lift rule

A hook starts in the component that needs it. When a second component needs the same logic, lift it to the lowest shared ancestor's `hooks/` folder. Only lift to `app/hooks/` when the hook is genuinely cross-cutting (breakpoint, viewport, timing primitives).

## Conventions

Named export, `use` prefix, one hook per file, kebab-case filename, tests in `app/hooks/tests/{name}.test.ts`. Use `/new-hook` to scaffold. See [[Coding Guidelines]] for file-naming rules.

For the current bundled inventory and signatures, query Serena (`.claude/rules/code-search.md`).

See the `react-code` skill (`.claude/skills/react-code/`) for `useEffect`, `useCallback`, `useState` rules.
