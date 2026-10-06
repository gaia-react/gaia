---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
---

# Route & Page Conventions

When editing routes or pages, fetch `wiki/decisions/Thin Routes.md` and `wiki/modules/Pages.md` for the canonical conventions (route thinness, page dir layout, loader meta pattern, i18n keys, Conform+Zod actions); group prefixes (flat `<group>.<name>` files): `wiki/modules/Routing.md`.

Route modules export `loader`, `clientLoader`, `action`, `clientAction`, `HydrateFallback`, and a one-line default render; which variant a route uses is the data-loading rule in `frontend/.claude/skills/react-code/SKILL.md`.

For scaffolding a new route, the `new-route` skill owns the templates - it auto-fires when the user asks to create or scaffold a route.
