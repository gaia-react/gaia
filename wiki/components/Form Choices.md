---
type: component
path: app/components/Form/{Checkbox,Checkboxes,CheckboxRadioGroup,InputRadio,RadioButtons}/
status: active
language: typescript
purpose: Checkbox and radio primitives plus grouped variants
depends_on:
  - "[[Form Components]]"
  - "[[Form Field]]"
created: 2026-04-20
updated: 2026-05-22
tags: [component, forms, checkbox, radio]
---

# Form Choices

Checkboxes and radios share a layout primitive (`CheckboxRadioGroup`) and a `Size` sizing table from `~/types` (`xs | sm | base | lg | xl`). Each component maps `size` to a `size-{n}` box class and a `text-{size}` label class so primitives stay visually consistent.

## Why these exist as separate primitives

- `Checkbox` / `InputRadio` are bare inputs — usable inline or inside group wrappers
- `Checkboxes` / `RadioButtons` add field chrome ([[Form Field]]) and group wiring
- `BaseRadioButtons` is the field-chrome-less variant for radios rendered outside a Field — keyed by `md5(option)` (`~/utils/object`) so duplicate values don't collide

## Non-obvious behaviour

> [!warning] `required` is gated on error state
> Both `Checkbox` and `InputRadio` only set `required` once an error surfaces. Setting it earlier makes the native browser steal focus on submit and breaks Conform's validation flow.

- `Checkboxes` derives `disabled` and `isRequired` by inspecting every option (`every(disabled)`, `every(required)`) — a single non-required option opts the group out of required
- `Checkbox` only wraps in `FieldStatus` when `description` or `error` is present — keeps the bare-input case clean
- `Checkboxes` gives the group a `useId` id and points every checkbox's `aria-describedby` at the shared `${id}-description` element, so a screen reader announces the group description on each option

## Decision tree

| Need                                      | Use                |
| ----------------------------------------- | ------------------ |
| Single checkbox (e.g. "I agree to terms") | `Checkbox`         |
| Group of independent checkboxes           | `Checkboxes`       |
| Group of mutually exclusive radios        | `RadioButtons`     |
| Radios rendered outside any Field chrome  | `BaseRadioButtons` |

For prop signatures and exact sub-component rosters, query Serena (`.claude/rules/code-search.md`).
