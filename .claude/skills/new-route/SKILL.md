---
name: new-route
description: Scaffold a new route with its page component, test, story, and optional i18n keys. Use this skill whenever the user asks to "create a route", "add a new page", "scaffold /dashboard", "wire up a new route under _public+ or _session+", or anything that implies adding a file under `app/routes/` with a matching `app/pages/{Group}/{PageName}/` folder.
model: haiku
---

# new-route

Trigger: user asks to add a new page/route.

## Workflow

1. Confirm with the user: name (kebab-case), group (`_public+` or `_session+`), and which of `--loader`, `--action`, `--i18n` they want.
2. Run: `gaia scaffold route <name> --group <group> [flags]`
3. Verify: `pnpm typecheck` clean; `pnpm dev` reaches the new route.

## Flags

- `--group` — required, `_public+` or `_session+`
- `--loader` — emit a loader stub
- `--action` — emit an action stub
- `--i18n` — emit the locale file and wire the locale barrel
- `--json` — print the scaffold result as JSON
