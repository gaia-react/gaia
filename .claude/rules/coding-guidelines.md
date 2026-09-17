# Coding Guidelines

## File Naming

- **Components**: PascalCase folders with `index.tsx`, tests/stories in `tests/` subfolder
- **Hooks**: camelCase with named export
- **Other files**: kebab-case

## 1. Simplicity First

Write no error handling for a state that cannot occur, but handle and bound real failure modes (a command exits non-zero, a loop does not converge, a network call fails).

## 2. Surgical Changes

Touch only what's needed: don't improve adjacent code, don't refactor unbroken things, match existing style. Remove only the imports/variables YOUR changes made unused; mention (don't delete) pre-existing dead code.

## 3. Always Use Test Driven Development

When building new features or fixing bugs, follow the TDD workflow described in `.claude/skills/tdd/SKILL.md` (read it on demand, do not preload).

- Use Vitest to test individual functions and components work in isolation
- Use Playwright to test user flows required by the feature specifications

## 4. Always Verify Your Work

Run the Quality Gate Process defined in `.claude/rules/quality-gate.md` (always-loaded as a rule; no `@`-import needed).

Don't hand-polish formatting or auto-fixable lint while authoring, the gate's `pnpm lint` (`eslint --fix`, with Prettier wired in as an `eslint` rule) normalizes it in one terminal pass. Spend tokens only on non-auto-fixable lint.
