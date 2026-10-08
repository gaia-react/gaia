---
name: new-route
description: Scaffolds a new route with its page component, page story, and optional i18n keys. Use this skill whenever the user asks to "create a route", "add a new page", "scaffold /dashboard", "wire up a new route under _public or _session", or anything that implies adding a file under `app/routes/` with a matching `app/pages/{name}/` folder.
model: haiku
---

# new-route

Trigger: user asks to add a new page/route.

## Workflow

1. Confirm with the user: name (kebab-case), group (`_public` or `_session`), whether the page loads service data (and which variant), and whether it needs `--action` or `--i18n`.
2. Run from the repo root: `./.gaia/cli/gaia scaffold route <name> --group <group> [flags]` (the package comes from the registry, not the working directory). Flags: `./.gaia/cli/gaia scaffold route --help`.
3. Verify: `pnpm typecheck` clean; `pnpm dev` reaches the new route.
4. Before filling in the page, loader, or action by hand, read one or two existing routes with a similar shape and follow their pattern.

The scaffold writes `app/routes/<group>.<name>.tsx` plus `app/pages/<name>/page.tsx` (export `<Name>Page`) with `tests/page.stories.tsx`, a page story whose play asserts the page structure (the story is the page's test, not a route test). It refuses the reserved page-folder names `tests`, `hooks`, `state`, `utils` and `assets`. Layout rule: `frontend/.claude/rules/coding-guidelines-react.md`.

## Data variants

Bind a service with `--data <server|client|query> --service <name> --shape <list|detail>`. The rule for choosing a variant lives in `frontend/.claude/skills/react-code/SKILL.md`; the default is `server`.

- `server`: a server `loader`, read with `useLoaderData`.
- `client`: a `clientLoader` and a `HydrateFallback`. The server renders only the `HydrateFallback`, so the first load shows its skeleton until the JavaScript loads and the `clientLoader` resolves, and the document's title and meta tags are the ones the `HydrateFallback` renders, never values from the loaded data.
- `query`: a `clientLoader` that primes the Query cache and a `HydrateFallback`, with the page reading `useSuspenseQuery`. Needs Query installed and the service's `queries.ts`; the same first-load and metadata cost as `client` applies.

`--shape list` writes the list route, and `--shape detail` writes the detail route (`app/pages/<name>/id/`); run both with the same name for the pair. A scaffolded page story drives MSW handlers through `stubs.reactRouter`.
