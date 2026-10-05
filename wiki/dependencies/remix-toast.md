---
type: dependency
status: active
package: 'remix-toast'
role: toasts
created: 2026-04-20
updated: 2026-10-05
tags: [dependency, ui]
---

# remix-toast

Cookie-backed flash messages for redirect-based UX, rendered by the shadcn `toast` component, which is built on Base UI's Toast primitive.

- `getToast(request)` extracts the cookie; `setToastCookieOptions` signs it; `dataWithToast(...)` returns toast-bearing action responses
- `notify[type](toast)` (`frontend/app/utils/notify.ts`) drives the ui `toast` manager; the bare `<Toaster />` from `~/components/ui/toast` displays it ([[shadcn Component Layer]])

See [[Form Submit Flow]].
