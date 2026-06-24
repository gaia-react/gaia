---
type: dependency
status: active
package: i18next
version: 26.3.1
role: i18n-core
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, i18n]
---

# i18next

Core i18n library that [[remix-i18next]] and `react-i18next` are built on. It is a direct dependency, and both [[remix-i18next]] and `react-i18next` declare it as a peer, so pnpm resolves a single shared copy and all consumers stay on the same version. Project-wide dependency overrides live in `pnpm-workspace.yaml`; see [[pnpm]].

See [[i18n]].
