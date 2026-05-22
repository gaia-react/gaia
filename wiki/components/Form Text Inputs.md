---
type: component
path: app/components/Form/{InputText,InputEmail,InputPassword,TextArea}/
status: active
language: typescript
purpose: Text-family form inputs — text, email, password, textarea
depends_on:
  - '[[Form Components]]'
  - '[[Form Field]]'
created: 2026-04-20
updated: 2026-05-04
tags: [component, forms, inputs]
---

# Form Text Inputs

`InputText` is the canonical base — `InputEmail` and `InputPassword` delegate to it with sensible defaults (autoComplete, label/placeholder from the `common` i18n namespace). `TextArea` is the multi-line sibling and uses the `autosize` library for `resize='auto'`.

## Why InputEmail / InputPassword exist as wrappers

Calling sites shouldn't have to remember `autoComplete='email'` and the matching i18n key. The wrappers bake those defaults in and forward everything else.

> [!warning] InputPassword's `type='password'` cannot be overridden
> The `type='password'` override is placed **after** `{...props}` spread inside `InputPassword`. Callers cannot accidentally change it to a `text` input, even by spreading. This is intentional — a password field that reveals plaintext from a forgotten prop is a bug magnet.

## Shared conventions

- `aria-label` cascade: explicit `aria-label` → string `label` → `name`. Never silently un-labelled.
- `readOnly` is rendered as `disabled` styling + `tabIndex={-1}` so the input is visually inert but still serializes its value
- Length tracking is local-only and only when `maxLength` is set
- `useImperativeHandle` exposes the textarea node to Conform (allows `.focus()` / form-level field control)

## Class merging

`twJoin` for static / conditional class lists; `twMerge` only when caller classes must override built-ins. See the `tailwind` skill (`.claude/skills/tailwind/`) and rule (`.claude/rules/tailwind.md`).

## Module convention

Every component exports a single default `FC` — no named component exports. Local component files extend `ComponentProps<'input'|'textarea'|'select'>` directly rather than reimporting through `~/components/Form/types`.

For prop signatures and the full inventory, query Serena (`.claude/rules/code-search.md`).
