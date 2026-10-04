---
type: decision
status: active
priority: 2
date: 2026-04-20
created: 2026-04-20
updated: 2026-10-04
tags: [decision, testing, components]
---

# Decision: Co-located `tests/` Subfolder

Tests and Storybook stories live in a `tests/` folder **next to** the component, not in a global `__tests__` tree.

## Rationale

- Co-location makes ownership obvious and refactoring atomic
- Sibling test files clutter the component folder when you also have `types.ts`, `utils.ts`, `styles.module.css`, etc.
- The `tests/` subfolder restored visual tidiness without giving up co-location
- Same pattern extends to `assets/`, `hooks/`, `state/`

## Enforcement

ESLint enforces the placement via `eslint-plugin-check-file/folder-match-with-fex` (stories and test files must live under a `tests/` folder), with `check-file/folder-naming-convention` restricting component subfolder names to `assets`, `hooks`, `state`, `tests`, `utils`, and nested kebab-case component folders; a story or test file is `tests/<source basename>.<kind>.tsx` (and `ui/tests/` for flat `ui/` components). See `frontend/.claude/rules/coding-guidelines-react.md`.

See [[Components]], [[Component Testing]].
