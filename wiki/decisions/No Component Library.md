---
type: decision
status: active
priority: 1
date: 2026-04-20
created: 2026-04-20
updated: 2026-04-20
tags: [decision, philosophy]
---

# Decision: No Component Library

GAIA ships zero UI components by default: no Material UI, Radix, shadcn, etc. The only components are infrastructure (Button, Form/, Toast, Layout); UI styling is intentionally minimal so each project can pick what fits.

## Rationale

- Component libraries lock in design opinions
- Replacing one later is painful
- The expensive part of project setup is **infrastructure** (lint, test, i18n, auth, MSW, Storybook), not buttons
- Projects vary on whether they want headless, opinionated, mobile-first, agency-bespoke, etc.

## Implications

- New projects must pick a UI library on day one (or roll their own)
- The Form components (Conform-bound) are the exception; they're the headline feature
- Storybook is included so whatever you pick has a place to live

See [[GAIA Philosophy]].
