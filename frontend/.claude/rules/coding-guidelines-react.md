---
paths:
  - 'app/**'
  - 'test/**'
  - '.playwright/**'
  - '.storybook/**'
---

# Coding Guidelines (React frontend)

The React half of `.claude/rules/coding-guidelines.md`; the universal principles stay there.

## File Naming

- **Components**: PascalCase folders with `index.tsx`, tests/stories in `tests/` subfolder
- **Hooks**: camelCase with named export

## Test Driven Development

- Use Vitest to test individual functions and components work in isolation
- Use Playwright to test user flows required by the feature specifications
