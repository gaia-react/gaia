---
type: component
path: app/components/Form/Field/
status: active
language: typescript
purpose: Label + input + status wrapper used by every GAIA Form component
depends_on: [[Form Components]]
created: 2026-04-20
updated: 2026-06-24
tags: [component, forms, wrapper]
---

# Form Field

The layout shell every other Form component wraps. Renders label, children, and a status block (description, error, max-length counter).

## Why every input reaches for Field

Inputs accept `description`, `error`, `extra`, and `label`, then forward them. Field owns the layout; inputs own the control + validation wiring. This keeps each input file focused on its native HTML element and lets Field evolve independently: change the status-row layout once, every input picks it up.

## Discriminated `type` prop

`type` discriminates which props are valid:

- `input` / `password` / `textarea`: has `name`, has `maxLength`
- `select`: has `name`, no `maxLength` (see [[Form Select]])
- `button` / `checkbox` / `radio`: no `name` / `maxLength` (group/action wrappers)
- `value`: display-only fields

This means a `type='button'` Field doesn't accept a `maxLength`; the type system enforces it.

## Status row: non-obvious behaviour

> [!key-insight] Spacer preserves alignment
> When a `MaxLength` counter is present but no description, `FieldStatus` inserts an empty spacer so the counter stays right-aligned. Removing the spacer collapses the row and the counter jumps left.

A `hideMaxLength` flag threads from the input through Field to FieldStatus; it suppresses the counter render while leaving `maxLength` enforcement intact.

Other behaviours worth knowing:

- `FieldLabel` renders `<label htmlFor>` only when the field wraps a single named input; group and display-only fields (`button` / `checkbox` / `radio` / `value`) have no input to point at and render a `<div>` instead, and `isLegend` switches it to `<legend>` ([[Form YearMonthDay]] uses the `<legend>` mode for its fieldset)
- `FieldRequiredText` flips colour on error state, a visual cue that a required field failed
- `FieldError` carries `role="alert"` so screen readers announce error text live; the surrounding `FieldStatus` wrapper is a plain `<div>`, so description changes are not in a live region
- The Field root wraps everything in a `<div role="presentation">`, removing the wrapper from the accessibility tree so the label, control, and status surface individually
- `FieldDescription` renders with id `${id}-description` and carries no ARIA role; inputs announce it by pointing `aria-describedby` at that id, which is the sole screen-reader association; a redundant role like `role="note"` adds nothing and risks a double announcement

For full prop signatures, query Serena (`.claude/rules/code-search.md`).

See [[Form Text Inputs]], [[Form Select]], [[Form Choices]] for the consumers.
