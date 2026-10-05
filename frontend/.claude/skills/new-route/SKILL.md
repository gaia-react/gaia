---
name: new-route
description: Scaffold a new route with its page component, test, story, and optional i18n keys. Use this skill whenever the user asks to "create a route", "add a new page", "scaffold /dashboard", "wire up a new route under _public or _session", or anything that implies adding a file under `app/routes/` with a matching `app/pages/<name>/` folder.
model: haiku
---

# new-route

Trigger: user asks to add a new page/route.

## Workflow

1. Confirm with the user: name (kebab-case), group (`_public` or `_session`), and which of `--loader`, `--action`, `--i18n` they want.
2. Run from the repo root: `./.gaia/cli/gaia scaffold route <name> --group <group> [flags]` (the package comes from the registry, not the working directory).
3. Verify: `pnpm typecheck` clean; `pnpm dev` reaches the new route.
4. Before filling in the page, loader, or action by hand, read one or two existing routes with a similar shape and follow their pattern.

The scaffold writes `app/routes/<group>.<name>.tsx` plus `app/pages/<name>/page.tsx` (export `<Name>Page`) with `tests/page.stories.tsx`, a page story whose play asserts the page structure (the story is the page's test). It refuses the reserved page-folder names `tests`, `hooks`, `state`, `utils` and `assets`. Layout rule: `frontend/.claude/rules/coding-guidelines-react.md`.

## Flags

- `--group`, required, `_public` or `_session`
- `--loader`, emit a loader stub
- `--action`, emit an action stub
- `--i18n`, emit the locale file and wire the locale barrel
- `--dry-run`, print what would be written without touching the filesystem
- `--json`, print the scaffold result as JSON
