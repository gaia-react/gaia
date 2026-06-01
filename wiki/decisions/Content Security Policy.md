---
type: decision
status: active
priority: 2
date: 2026-05-21
created: 2026-05-21
updated: 2026-06-02
tags: [decision, security, csp]
---

# Decision: Content Security Policy

GAIA serves a per-request nonce-based Content Security Policy. `handleRequest`
(`app/entry.server.tsx`) generates a 16-byte hex nonce per request and threads
it through `NonceProvider` and `ServerRouter`; `getContentSecurityPolicy`
(`app/utils/http.server.ts`) builds the policy string with that nonce.

## Enforced

The policy ships under the enforcing `Content-Security-Policy` header. Every
server-rendered and streamed script carries the per-request nonce — React
Router's single-fetch stream scripts and post-shell chunks included — so
enforcement does not block hydration. App-authored inline scripts read the
nonce through `useNonce()`: the `window.process` ENV bootstrap in
`app/root.tsx`, and the dark-mode probe plus `ScrollRestoration` / `Scripts` in
`app/components/Document`.

## Trade-offs

- **`style-src 'unsafe-inline'`.** The Google Fonts stylesheet injects an
  inline `<style>` block that cannot carry a nonce, so `style-src` keeps
  `'unsafe-inline'`. This forfeits CSP protection for styles. Self-hosting the
  Inter font (already loaded from `fonts.gstatic.com`) eliminates the inline
  stylesheet and lets `'unsafe-inline'` drop — the path to take if style-level
  CSP protection becomes a requirement.
- **No reporting endpoint.** The policy carries no `report-uri` / `report-to`
  directive. A violation-reporting pipeline is adopter-owned infrastructure,
  out of scope for the template.

## Code review

The `code-review-audit` agent reviews the branch diff, so a PR that touches
`app/utils/http.server.ts` or `app/entry.server.tsx` re-surfaces the
`'unsafe-inline'` and missing-`report-uri` observations — they sit in the diff
scope. Both are accepted trade-offs, recorded here and in code comments at the
directives themselves, not regressions.

See [[Dark Mode Modernization]].
