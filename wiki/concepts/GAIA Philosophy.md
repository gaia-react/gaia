---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, philosophy]
---

# GAIA Philosophy

GAIA deliberately ships **no component library**; you choose what fits.

## Core tenets

1. **Pre-configured but removable: ask Claude to swap.** Don't need i18n? Tell Claude to rip it out. Prefer different icons? Ask Claude to swap them in. Because Claude understands how the pieces are wired, removals and substitutions stay coherent. Nothing is locked in.
2. **Quality enforced by tooling, not vigilance.** 20+ ESLint plugins + pre-commit hooks + the [[Quality Gate]] catch issues before they compound.
3. **Working examples, not just installs.** Every tool ships with a real, working example: i18n wired up with a working English locale and the full namespace structure ready for more (the init flow lets you add locales), MSW handlers for tests and Storybook, Conform-validated forms.
4. **Co-location with discipline.** Tests, stories, assets, hooks, state live next to the component, but in their own subfolders so the component folder stays scannable.
5. **Thin routes, fat pages.** Routes do data; pages do UI. See [[Thin Routes]].
6. **Best practices baked in.** Patterns over docs.

## What GAIA explicitly avoids

- A component library (see [[No Component Library]])
- A specific deployment target; uses default React Router deploy, you pick the host
- Heavy state management (no Redux, Zustand); Context+Provider is enough
- Backend assumptions (no Prisma, Drizzle, etc.); your services layer talks to your API

## Positioning & Naming

GAIA is **not just a React template**; it is a complete workflow for building React sites with Claude. Calling it a "template" undersells the scope. Lead with "workflow" / "system" / "Claude-first" framing.

GAIA is React-specific, built on [[React Router]]. There is no multi-framework roadmap.
