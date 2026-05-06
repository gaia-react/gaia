---
type: component
path: app/components/Form/Select/
status: active
language: typescript
purpose: Native select dropdown with icon, optgroup, and placeholder support
depends_on:
  - "[[Form Components]]"
  - "[[Form Field]]"
created: 2026-04-20
updated: 2026-05-04
tags: [component, forms, select]
---

# Form Select

Native `<select>` wrapped by [[Form Field]]. **No custom dropdown UI — deliberate.** Native selects are accessible and mobile-friendly for free; rebuilding them in JS forfeits both.

## Option shape — flat or grouped

`SelectOption` (defined in `Select/types.ts`) is a discriminated union: a single option gives `{value, label}`; a group gives `{label, options: Option[]}` and renders as `<optgroup>`. **No nested groups** — HTML `<optgroup>` doesn't support nesting, and the type prevents the mistake at the call site.

## Placeholder coloring — `unselected`

When `unselected` is passed, the component renders a top `<option value="">`. Text color flips between `text-placeholder` (while empty) and `text-body` (once a real option is picked). The flip is driven by a local `currentValue` — purely cosmetic.

## Controlled / uncontrolled duality

`currentValue` exists **only** to drive placeholder coloring. The actual submitted value is whatever React gives the `<select>` — Select stays controllable via `value` or `defaultValue`. Consumer `onChange` still fires.

> [!warning] Don't use raw Select inside custom stateful components without Conform
> If you bundle Select into a parent that manages state (like [[Form YearMonthDay]]) and submit via Conform, you need `useInputControl`. The local state here is cosmetic; it is not the submission source of truth.

## Icon positioning

- Left icon absorbs `pl-[2.3rem]` on the `<select>`; right icon uses `pr-[2.3rem]`
- Icon color follows disabled/placeholder state
- `classNameIcon` overrides `top-*` for custom vertical centering (e.g. larger option text)

For prop signatures, query Serena (`.claude/rules/code-search.md`). See [[Form YearMonthDay]] for the three-Select composite.
