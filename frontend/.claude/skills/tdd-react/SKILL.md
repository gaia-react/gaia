---
name: tdd-react
description: React testing reference for the tdd skill. Test layers, the three Vitest projects, Storybook stories with play functions as component tests, vitest-browser-react hook tests, MSW, and Playwright patterns for the frontend package. Use when writing or reviewing tests under frontend/ as part of a red-green-refactor loop, choosing a test layer, mocking HTTP, or testing a component, hook, or service.
---

# TDD for React (frontend package)

The stack reference the generic `tdd` skill (`.claude/skills/tdd/SKILL.md`) points at for the React frontend. The red-green-refactor loop, the RED gate, the determinism roll-up, and the worthiness audit live in `tdd`; this skill holds only the React and Vitest specifics: components and pages are tested by Storybook stories with play functions (headless Chromium, `pnpm install:browsers` once), hooks by `vitest-browser-react`, pure and server code in the `node` project.

Read [references/tests-react.md](references/tests-react.md) before writing the first red test. Paths in the reference (`app/`, `test/`, `.playwright/`) are relative to the `frontend/` package directory.
