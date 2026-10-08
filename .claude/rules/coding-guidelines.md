# Coding Guidelines

## File Naming

- **Other files**: kebab-case
- **React components and hooks** (file and folder layout, naming): `frontend/.claude/rules/coding-guidelines-react.md`, loaded on frontend files

## 1. Simplicity First

Write no error handling for a state that cannot occur, but handle and bound real failure modes (a command exits non-zero, a loop does not converge, a network call fails).

## 2. Surgical Changes

Touch only what's needed: don't improve adjacent code, don't refactor unbroken things, match existing style. Remove only the imports/variables YOUR changes made unused; mention (don't delete) pre-existing dead code.

## 3. Always Use Test Driven Development

When building new features or fixing bugs, follow the TDD workflow described in `.claude/skills/tdd/SKILL.md` (read it on demand, do not preload).

- Test individual functions in isolation and user flows end to end; the frontend stack (Vitest, Playwright) is in `frontend/.claude/rules/coding-guidelines-react.md`

## 4. Always Verify Your Work

Quality Gate: `.claude/rules/quality-gate.md`.

Don't hand-polish formatting or auto-fixable lint while authoring, the gate's `pnpm lint` (`eslint --fix`, with Prettier wired in as an `eslint` rule) normalizes it in one terminal pass. Spend tokens only on non-auto-fixable lint.
