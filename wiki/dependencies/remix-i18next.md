---
type: dependency
status: active
package: remix-i18next
version: 8.0.0
role: i18n
created: 2026-04-20
updated: 2026-06-27
tags: [dependency, i18n]
---

# remix-i18next

i18n integration built on `i18next` for React Router. GAIA wires it through middleware (`app/middleware/i18next.ts`) and exposes server-side translation for loaders via `getInstance(context)`. All exports come from the bare `remix-i18next` package; there are no subpath exports. The package peers `react-router ^8`.

## Companion

- `i18next` 26.3.1
- `react-i18next` 17.0.8
- `i18next-browser-languagedetector` 8.2.1
- `accept-language-parser` 1.5.0
- `storybook-react-i18next` 10.1.2

> [!note] Single shared version, no forcing override
> `i18next`, `react-i18next`, and `remix-i18next` are each declared as direct dependencies, so pnpm resolves a single shared copy of each (`remix-i18next` declares `i18next`/`react-i18next` as peers, `react-i18next` declares `i18next` as a peer) and consumers stay on one version without any override. Dependency `overrides` live in `pnpm-workspace.yaml` (pnpm 11 ignores the package.json `pnpm` field); the only current override is a security floor on `qs`. See [[pnpm]] and [[pnpm-overrides]] for the override audit flow.

## Client wiring

The server middleware resolves the request language; the browser entry (`app/entry.client.tsx`) initializes its own `i18next` instance with `.use(LanguageDetector)` from `i18next-browser-languagedetector`, detecting the language client-side from the `htmlTag` set during SSR.

See [[i18n]], [[Language Flow]].
