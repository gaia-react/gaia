---
type: dependency
status: active
package: react-router
version: 8.0.1
role: framework
created: 2026-04-20
updated: 2026-06-27
tags: [dependency, framework]
---

# React Router

The full-stack web framework GAIA is built on. Provides SSR, file-based routing, loaders, actions, middleware. Web routing primitives live in `react-router` directly; there is no separate `react-router-dom` package. Middleware, route-module splitting, and the Vite Environment API are built-in defaults with no future-flag opt-ins required.

## Companion packages (kept in version lockstep)

- `@react-router/node`
- `@react-router/serve`
- `@react-router/dev`
- `@react-router/fs-routes`
- `@react-router/remix-routes-option-adapter`

The `/update-deps` command upgrades all of these together when react-router is selected.

## Used by

- [[Routing]] (with [[remix-flat-routes]] adapter)
- [[Middleware]]
- [[Sessions]] (`createCookie`)

## Related

- [[remix-flat-routes]], [[remix-i18next]], [[remix-toast]]
