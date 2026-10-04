---
type: flow
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [flow, forms, conform, zod]
---

# Form Submit Flow

The end-to-end path of a form submission in the app.

1. User fills out a form composed from ui `Field` parts, ui controls and Conform ([[Form Components]]).
2. Conform's `useForm({ onValidate })` runs `parseWithZod(formData, {schema})` client-side for instant feedback.
3. On submit, the form `POST`s to the route's `action`.
4. The route action runs the **same** `parseWithZod` server-side (source of truth). Import it from `@conform-to/zod/v4`; the package-root `@conform-to/zod` selects Zod-v3 behavior and silently breaks v4 schemas (see [[Conform]]):
   ```ts
   import {parseWithZod} from '@conform-to/zod/v4';

   const submission = parseWithZod(formData, {schema});
   if (submission.status !== 'success') return submission.reply();
   ```
5. On success, action does the work (call API via `frontend/app/services/`), then either:
   - Returns `redirect(...)` for a navigation
   - Returns `dataWithToast(...)` from `remix-toast` for an inline toast
6. Conform binds errors back to fields automatically.

This is the recommended template pattern. No shipped route action implements it; the live working example is the composed form fixture and its story under `frontend/app/components/form/tests/`. The shipped route actions (`frontend/app/routes/actions.set-language.ts`, `frontend/app/routes/resources.theme-switch.tsx`) validate with plain `z.safeParse` rather than `parseWithZod`/`submission.reply()`.

## Stateful custom inputs

If the form contains a stateful custom input (e.g. `YearMonthDay`), wire it via `useInputControl` so it stays in sync with Conform's validation state. See [[Form Components]].

## Toasts

`remix-toast` cookie + Sonner UI render success/error toasts on redirect. The root loader reads the toast via `getToast(request)` and returns it in loader data. The root `App` component's `useEffect` calls `notify[toast.type](toast)` when a toast is present, and the `ui/sonner` `Toaster`, mounted in the root with `toasterProps`, displays it.

See [[Routing]], [[Form Components]], [[i18n]].
