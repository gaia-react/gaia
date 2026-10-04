---
type: module
path: frontend/app/components/form/
status: active
language: typescript
purpose: Conform + Zod-powered form components
depends_on:
  - '[[Conform]]'
  - '[[Zod]]'
created: 2026-04-20
updated: 2026-10-05
tags: [module, components, forms]
---

# Form Components

GAIA has no form wrapper components. A form is composed from the ui `Field` parts and ui controls ([[shadcn Component Layer]]) with [[Conform]] and [[Zod]] supplying the props, ids and validation state. Each control's accessible name, invalid state, required state and keyboard behavior come from the ui component plus Conform's attributes, not from a GAIA abstraction.

## The composed pattern

For each field: a ui `Field` (with `data-invalid` when the field has errors) holding a `FieldLabel` (`htmlFor` the field id), the control (`Input`, `Textarea`, `NativeSelect`, `Checkbox`, `RadioGroup`) spread with Conform's `getInputProps`, `getSelectProps` or `getTextareaProps`, an optional `FieldDescription`, and a `FieldError` (`id` the field's `errorId`). Groups of checkboxes or radios sit in a `FieldSet` with a `FieldLegend`; checkboxes share one name through `getCollectionProps`. The submit button is a `ui/button` that shows a `ui/spinner` and disables itself while the navigation is submitting.

The step-by-step pattern, the Zod schema and action wiring, and error-message translation are in `frontend/.claude/skills/react-code/references/conform-forms.md`. The runnable reference is `frontend/app/components/form/tests/composed-form.tsx` and its story and test.

## App-logic form components

- `FormError`: top-of-form error summary built on ui `Alert`.
- `MaxLength`: character counter for length-limited fields.
- [[Form YearMonthDay]]: composite date input; documents the Conform gotchas.

For the current inventory, query Serena (`.claude/rules/code-search.md`).

## Conform + custom components

> [!warning] useInputControl is mandatory for stateful custom components
> When using custom form components that manage their own internal state (e.g. `YearMonthDay`), you **must** use `useInputControl` to keep them in sync with Conform's validation state. Local `useState` becomes disconnected from Conform once validation fails.

```tsx
const fieldControl = useInputControl(fields.fieldName);

<CustomComponent
  onBlur={fieldControl.blur}
  onChange={fieldControl.change}
  value={fieldControl.value ?? DEFAULT}
/>;
```

See [[Component Testing]] for the canonical example (`year-month-day/tests/`).

## Validation

- Use `parseWithZod(formData, {schema})` in actions
- Schemas live next to the component or as part of the action
- Server-side validation is the source of truth; client validation just provides UX

## Accessibility

Label association comes from `FieldLabel htmlFor` pointing at the Conform field id, and error association from `aria-describedby` pointing at `errorId`. For custom inputs, ensure `<label htmlFor>` or `aria-label`. See [[Accessibility]].
