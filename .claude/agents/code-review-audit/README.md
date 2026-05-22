# code-review-audit Extensions

This directory contains library-specific audit rules for the `code-review-audit` agent (`.claude/agents/code-review-audit.md`). The extension mechanism is part of a broader Claude-integration convention documented in `wiki/concepts/Claude Integration Conventions.md`.

## How it works

At startup the agent Globs `*.md` files in this directory (skipping this README), reads each one, parses its `subagents:` frontmatter field, and injects the file's content into the matching specialist subagent's prompt before dispatching.

If this directory is empty or missing, the agent runs its generic review without library-specific checks.

## Extension file format

```yaml
---
subagents: [react-patterns, typescript, translation]
library: package-name
---
```

Valid `subagents` values map to the three specialist subagents:

- `react-patterns` → Subagent 1 (`.tsx` files: hooks, components, accessibility)
- `typescript` → Subagent 2 (`.ts` + `.tsx` files: types, architecture, conventions)
- `translation` → Subagent 3 (files with `useTranslation` / `t(` calls)

`library` is documentation only — it identifies which dependency this file covers.

## When to update

| Event                                                                           | Action                                              |
| ------------------------------------------------------------------------------- | --------------------------------------------------- |
| Add a library with audit-worthy patterns (form validation, styling, i18n, etc.) | Create a new extension file                         |
| Remove a library                                                                | Delete its extension file                           |
| Replace a library (e.g. Conform → react-hook-form)                              | Delete the old file, create one for the replacement |
| Library has a major API change that invalidates its rules                       | Update the file                                     |

## Current extensions

| File                 | Library              | Subagents                  |
| -------------------- | -------------------- | -------------------------- |
| `conform.md`         | `@conform-to/zod`    | react-patterns, typescript |
| `tailwind-merge.md`  | `tailwind-merge`     | typescript                 |
| `react-i18next.md`   | `react-i18next`      | translation                |
| `form-components.md` | GAIA Form Components | react-patterns             |
