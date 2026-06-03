# {{PROJECT_TITLE}}

## Quick start

```bash
pnpm dev
```

The dev server runs on [http://localhost:3000](http://localhost:3000).

## Common scripts

- `pnpm dev`: start the dev server

## Useful Claude commands

This project ships with [GAIA](https://gaiareact.com/). Run these slash commands from inside Claude Code:

- `/gaia-plan`: plan a feature as a graph of tasks and execute via subagents
- `/gaia-spec`: run Socratic discovery and produce an immutable SPEC artifact
- `/gaia-handoff` and `/gaia-pickup`: clear context without losing state across sessions
- `/gaia-forensics`: file a redacted, classified report when GAIA itself misfires

## Knowledge base

`wiki/` is an [Obsidian](https://obsidian.md/) vault. Open the folder in Obsidian for a graph view, backlinks, and canvas boards. Claude reads from it as the project's source of truth. Architecture decisions, conventions, and "where we left off" all live here.

## Learn more

- GAIA docs: [https://docs.gaiareact.com/](https://docs.gaiareact.com/)
