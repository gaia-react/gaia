---
type: dependency
status: active
package: 'remix-toast, sonner'
role: toasts
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, ui]
---

# remix-toast + Sonner

Cookie-backed flash messages for redirect-based UX, rendered with [Sonner](https://sonner.emilkowal.ski/).

- `getToast(request)` extracts the cookie; `setToastCookieOptions` signs it; `dataWithToast(...)` returns toast-bearing action responses
- `<Toast />` subscribes; `notify[type](toast)` triggers render

See [[Form Submit Flow]].
