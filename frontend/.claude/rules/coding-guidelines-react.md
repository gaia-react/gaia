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

This section owns the layout rule. Every other rule, skill, agent and wiki page points here instead of restating it.

- **Case**: every file and folder under `app/components`, `app/pages` and `app/hooks` is kebab-case, ASCII English.
- **Components**: `components/ui/` holds flat shadcn files (`button.tsx`) and its only subfolder is `tests/`. Any other component is `<kebab>/index.tsx` with a default export that is the PascalCase of the folder, plus nested `tests/`, `hooks/` and sub-component folders (`<kebab-sub>/index.tsx`).
- **Tests and stories**: `tests/<source basename>.<kind>.tsx`; the exact shape lives in `storybook.md`.
- **Pages**: `pages/<route path>/page.tsx` exporting `<Name>Page`. Derive the folder from the route file name: drop pathless-layout segments (leading `_`), turn each `.` into a nested folder, keep static segments as they are, `_index` becomes `index`, `$slug` becomes `slug`, `$` becomes `splat`, optional `($x)` segments drop out. `_public.about.tsx` becomes `pages/about/page.tsx`; `account._index.tsx` becomes `pages/account/index/page.tsx`. A trailing nesting-escape underscore on a static segment is dropped (`_public.items_.$id.tsx` becomes `pages/items/id/page.tsx`). On a rare collision between a derived folder and a static sibling, pick a distinguishing name. Route files keep their names and import `~/pages/<path>/page`.
- **Colocation**: page content lives in its page folder (`pages/<path>/<kebab>/index.tsx`, with its own `tests/`). A multi-page or global component, and any app chrome (header, footer, nav, menus, theme and language switchers), is top-level `components/<name>/`. A grouping folder (`errors/`, `form/`) exists only for a real family. There is no `shared/` folder.
- **Reserved names**: `assets`, `hooks`, `state`, `tests` and `utils` are the only non-component subfolders inside a component or page folder; a page folder never takes one of them as its own name.
- **Hooks**: a component- or page-local hook is that folder's `hooks/use-<name>.ts` (test in `hooks/tests/use-<name>.test.ts`); lift it to `app/hooks/` when a second consumer appears. Shared hooks are `app/hooks/use-<name>.ts` with a camelCase named export (`use-breakpoint.ts` exports `useBreakpoint`).

## Test Driven Development

- Components and pages are tested by their Storybook stories (play functions run by Vitest in headless Chromium), hooks with `vitest-browser-react`, and pure and server code in the `node` Vitest project; the rules are in `storybook.md` and the `tdd-react` skill
- Use Playwright to test user flows required by the feature specifications
