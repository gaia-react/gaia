---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
---

# Route & Page Conventions

For scaffolding a new route, run `/new-route` — it owns the canonical templates. This file covers the conventions that apply when *editing* existing routes/pages.

- **Route files are thin.** `app/routes/` handles loader, action, meta-via-loader, and rendering the page. All UI lives in `app/pages/`.
- **Route groups** (remix-flat-routes `+` suffix): `_public+` (unauthenticated), `_session+` (auth-guarded hook), `_legal+` (terms, privacy), `actions+` (form endpoints).
- **Page dirs**: `app/pages/{Group}/{PascalName}Page/index.tsx` — e.g. `app/pages/Public/IndexPage/`.
- **Meta tags**: set `title`/`description` in the loader via `getInstance(context).t(...)`, render as `<title>` / `<meta>` in the route component (see `app/routes/_public+/_index.tsx`).
- **i18n**: all user-facing strings via `useTranslation('pages', {keyPrefix})`. Add keys to every folder under `app/languages/`.
- **Actions**: Zod + Conform — `parseWithZod(formData, {schema})`.
