---
type: dependency
status: active
package: remix-utils
version: 9.3.1
role: utility-belt
created: 2026-06-25
updated: 2026-06-25
tags: [dependency, claude, decision-map]
---

# remix-utils

A decision map for the bundled `remix-utils` belt: *when* to reach for a utility instead of hand-rolling a primitive that is redundant or subtly wrong. For *how* each one works, see `node_modules/remix-utils/README.md`, cited below by section title.

## Decision map

Risk-sorted, footguns first. Each row pairs a trap to hand-roll with the resolvable subpath that solves it safely and the README section that documents it.

| DIY trap | Reach for | Why safer | README section |
|---|---|---|---|
| Hand-rolled client-only / hydration guard (`useState` + `useEffect` flag) | `remix-utils/use-hydrated` (component-wrapper sibling: `remix-utils/client-only`) | `useSyncExternalStore`-based, no provider, avoids hydration mismatch; in-repo usage: `app/components/Document/MetaHydrated/index.tsx` | `### useHydrated` (and `### ClientOnly`) |
| Hand-rolled SSE hook / `EventSource` wiring | `remix-utils/sse/react` (server emitter: `remix-utils/sse/server`) | Manages the connection lifecycle and cleanup; a hand-rolled hook leaks connections | `### Server-Sent Events` |
| Hand-rolled CSRF token + verification | `remix-utils/middleware/csrf` (classic split `remix-utils/csrf/server` + `remix-utils/csrf/react` for non-middleware routes) | Battle-tested token generation and verification; rolling your own is a security footgun | `#### CSRF Middleware` (classic: `### CSRF`) |
| Hand-rolled bot/spam honeypot field | `remix-utils/middleware/honeypot` (classic split `remix-utils/honeypot/server` + `remix-utils/honeypot/react` for non-middleware routes) | Correct hidden-field plus timing checks; ad-hoc honeypots miss the timing trap | `#### Honeypot Middleware` (classic: `### Form Honeypot`) |
| Hand-rolled open-redirect / safe-redirect check | `remix-utils/safe-redirect` | Blocks `//` and `/\` protocol-relative escapes; naive checks miss them. In GAIA code, see the redirect divergence below: use `isLocalRedirect` | `### Safe Redirects` |
| Hand-rolled fetcher debounce (timeout wrapping `fetcher.submit`) | `remix-utils/use-debounce-fetcher` | Correct debounced `fetcher.submit`; distinct from a value debounce | `### Debounced Fetcher and Submit` |

**Surface choice (CSRF and honeypot).** GAIA runs a middleware stack (`app/middleware/i18next.ts`), so each of those rows points at the v7.9 middleware subpath as the canonical surface for new code, with the classic split named in parentheses for routes that do not run through middleware. They are a different mechanism, not a fallback: middleware wires the check into the request pipeline; the classic split is the per-route hook plus server helper.

## Considered but excluded

Second-tier candidates weighed against the risk axis (likelihood-of-hand-rolling times cost-of-getting-it-wrong) and cut, so the curation is transparent rather than a silent cap:

- `cache-assets` (`remix-utils/cache-assets`): lower-stakes perf convenience.
- `preload-route-assets` (`remix-utils/preload-route-assets`): lower-stakes perf convenience.
- `use-global-navigation-state` (`remix-utils/use-global-navigation-state`): lower-stakes convenience reinvention.

## Deliberate divergences

Where GAIA intentionally does not reach for remix-utils, with the reason, so the choice is not re-litigated:

- **locale** → GAIA uses `remix-i18next` (full i18next: namespaces, SSR `Accept-Language`), more robust than remix-utils locales. See [[remix-i18next]].
- **redirect** → GAIA uses a Zod `.refine()` `isLocalRedirect` guard (`app/utils/http.ts`). Validate-and-reject fits GAIA's Conform/Zod architecture better than safe-redirect's sanitize-and-fallback, and the safety is equivalent (both block `//` and `/\`). This is the in-GAIA position for the safe-redirect core row above: know the open-redirect trap, and in GAIA code guard with `isLocalRedirect`.
- **responses** → GAIA uses native React Router 7 `data()`, the modern idiom over remix-utils `responses`.
- **cookie** → GAIA uses native `createCookie`; locale is a known string, so a typed-cookie wrapper is low value.
- **value-debounce** → GAIA's `useDebounce` is a *value* debounce, which is **not** remix-utils' fetcher-debounce (`use-debounce-fetcher`). No overlap, so both coexist.

## Where each layer lives

`node_modules/remix-utils/README.md` is the how, this map is the when, and the two trigger surfaces (the `react-code` skill's platform-first ladder and the `react-router-docs` path-scoped rule) are the awareness that points here.
