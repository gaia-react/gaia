# Frontend

The React app: routes, pages, components, services, tests, Storybook, Playwright. Its rules and skills live in `frontend/.claude/` and load when Claude works inside this directory; a root session loads them by Reading this file first.

## Conventions

- The visual styling is a deliberate neutral baseline, not a chosen design system; before designing or restyling read `frontend/.claude/rules/design-baseline.md` and `wiki/concepts/Design System.md`.
- Rules in `frontend/.claude/rules/` scope themselves to the package paths each rule's `paths:` frontmatter names; skills in `frontend/.claude/skills/` cover scaffolding, React, TypeScript, Tailwind, a11y, ESLint fixes, and Playwright. List the directories rather than relying on a copy of the list here.
- Paths in prose inside these rules and skills (`app/`, `test/`, `.playwright/`, `.storybook/`, `public/`, config files) are relative to `frontend/`. Shell commands are written to run from the repo root, so they carry the `frontend/` prefix or use the root `pnpm` proxies.
- `.claude/`, `.gaia/`, and `wiki/` paths are repo-root paths; the frontend's own units appear as `frontend/.claude/...`.

## Running the gate

`pnpm <script>` from `frontend/` equals `pnpm -C frontend <script>` from the repo root, and the root `package.json` proxies every frontend script, so `pnpm typecheck`, `pnpm lint`, `pnpm test`, and `pnpm pw` work from either directory. The Quality Gate steps live in `wiki/decisions/Quality Gate.md`.

The harness CLI lives at the repo root: run `./.gaia/cli/gaia ...` from the root, or `../.gaia/cli/gaia ...` from `frontend/`. Scaffolders find the package through `.gaia/packages.json`, not the working directory.

## Harness workflows

Harness workflows (`/gaia-spec`, `/gaia-plan`, PR merge, release, `/gaia-debt`, `/update-gaia`) run from a root launch, never from `frontend/`.
