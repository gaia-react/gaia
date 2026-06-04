# Coding Guidelines

## File Naming

- **Components**: PascalCase folders with `index.tsx`, tests/stories in `tests/` subfolder
- **Hooks**: camelCase with named export
- **Other files**: kebab-case

## 1. Think Before Coding

Surface assumptions explicitly, present interpretations when ambiguous, push back when a simpler approach exists, and stop to ask when anything is unclear.

## 2. Simplicity First

Write the minimum code that solves the problem, no speculative features, abstractions, or impossible-scenario error handling. If it could be 50 lines, don't write 200.

## 3. Surgical Changes

Touch only what's needed: don't improve adjacent code, don't refactor unbroken things, match existing style. Remove only the imports/variables YOUR changes made unused; mention (don't delete) pre-existing dead code.

## 4. Goal-Driven Execution

Define verifiable success criteria before starting; loop until verified. For multistep tasks, state a brief plan with steps and verification checks.

## 5. Always Use Test Driven Development

When building new features or fixing bugs, follow the TDD workflow described in `.claude/skills/tdd/SKILL.md` (read it on demand, do not preload).

- Use Vitest to test individual functions and components work in isolation
- Use Playwright to test user flows required by the feature specifications

## 6. Always Verify Your Work

Run the Quality Gate Process defined in `.claude/rules/quality-gate.md` (always-loaded as a rule; no `@`-import needed).

Don't hand-polish formatting or auto-fixable lint while authoring, the gate's `pnpm lint` (`eslint --fix`, with Prettier wired in as an `eslint` rule) normalizes it in one terminal pass. Spend tokens only on non-auto-fixable lint.
