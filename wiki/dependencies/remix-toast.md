---
type: dependency
status: active
package: 'remix-toast, sonner'
role: toasts
created: 2026-04-20
updated: 2026-10-05
tags: [dependency, ui]
---

# remix-toast + Sonner

Cookie-backed flash messages for redirect-based UX, rendered with [Sonner](https://sonner.emilkowal.ski/).

- `getToast(request)` extracts the cookie; `setToastCookieOptions` signs it; `dataWithToast(...)` returns toast-bearing action responses
- `notify[type](toast)` (`frontend/app/utils/notify.tsx`) calls sonner's `toast.*`; the `ui/sonner` `Toaster`, rendered with `toasterProps`, subscribes and displays it ([[shadcn Component Layer]])

See [[Form Submit Flow]].
