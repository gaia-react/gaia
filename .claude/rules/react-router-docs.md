---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
  - 'app/root.tsx'
  - 'react-router.config.ts'
---

# React Router Docs

When working on React Router framework-mode code (routes, loaders/actions, navigation, pending/optimistic UI, error boundaries, rendering strategies, `react-router.config.ts`), read the docs shipped with the **installed** React Router rather than the web, they match the pinned version (React Router 7.17.0+ ships them as markdown):

```bash
ls node_modules/react-router/docs   # explanation/ how-to/ start/ upgrading/ index.md
```

Reach for the online docs (`reactrouter.com/docs`) only when the local copy is absent (older React Router) or a topic is missing.

This rule covers React Router's **own API**. GAIA's route/page structure conventions (thin routes, group folders, page-dir layout, loader meta) are governed separately by the Route & Page Conventions rule and `wiki/decisions/Thin Routes.md`.
