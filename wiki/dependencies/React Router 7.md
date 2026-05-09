---
type: dependency
status: active
package: react-router
version: ^7.14.1
role: framework
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, framework]
---

# React Router 7

The full-stack web framework GAIA is built on. Provides SSR, file-based routing, loaders, actions, middleware.

## Companion packages (kept in version lockstep)

- `@react-router/node`
- `@react-router/serve`
- `@react-router/dev`
- `@react-router/fs-routes`
- `@react-router/remix-routes-option-adapter`
- `react-router-dom`

The `/sharpen` command upgrades all of these together when react-router is selected.

## Used by

- [[Routing]] (with [[remix-flat-routes]] adapter)
- [[Middleware]]
- [[Sessions]] (`createCookieSessionStorage`, `redirect`)

## Related

- [[remix-flat-routes]], [[remix-i18next]], [[remix-toast]]
