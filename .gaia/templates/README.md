# {{PROJECT_TITLE}}

## Quick start

```bash
pnpm install
pnpm dev
```

The dev server runs on [http://localhost:3000](http://localhost:3000).

## Common scripts

- `pnpm dev` — start the dev server
- `pnpm build` — production build
- `pnpm test` — run unit tests
- `pnpm typecheck` — TypeScript type-check
- `pnpm lint` — lint the codebase

## Useful Claude commands

This project ships with [GAIA](https://gaiareact.com/) — a workflow built on Claude Code with slash commands for common tasks:

- `/update-gaia` — pull the latest GAIA release into the project (three-way merge, preserves your customizations)
- `/update-deps` — autonomous dependency upgrades; audits overrides, applies safe bumps, runs the quality gate
- `/orchestrate` — plan a feature as a graph of tasks and execute them via sub-agents
- `/handoff` — generate a session handoff document for the next developer (or next session)
- `/pickup` — restore context from a handoff document and continue work
- `/audit-knowledge` — audit memory, wiki, and auto-loaded files for duplication and load cost

Run any of these from inside Claude Code.

## Knowledge base

`wiki/` is an [Obsidian](https://obsidian.md/) vault. Open the folder in Obsidian for a graph view, backlinks, and canvas boards. Claude reads from it as the project's source of truth — architecture decisions, conventions, and "where we left off" all live here.

## Learn more

- GAIA docs: [https://gaiareact.com/](https://gaiareact.com/)
