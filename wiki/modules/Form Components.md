---
type: module
path: app/components/Form/
status: active
language: typescript
purpose: Conform + Zod-powered form components, the star of GAIA
depends_on:
  - '[[Conform]]'
  - '[[Zod]]'
created: 2026-04-20
updated: 2026-06-24
tags: [module, components, forms]
---

# Form Components

> [!key-insight] The star of GAIA
> GAIA's form components are the headline feature. Built on [[Conform]] + [[Zod]], they handle label association, validation state, error display, and accessibility automatically.

## Replace native inputs

Per [[Coding Guidelines]]: use these instead of native `<input>`, `<select>`, `<textarea>`. Exceptions: `<input type="hidden">`, `<input type="file">`, `<input type="radio">` inside custom radio groups.

## Deep dives by component family

- [[Form Field]]: label + input + error wrapper that every other Form component composes
- [[Form Layout]]: `Chain`, `FormActions`, `FormError`
- [[Form Text Inputs]]: `InputText`, `InputEmail`, `InputPassword`, `TextArea`
- [[Form Select]]: native select with icon, optgroup, placeholder
- [[Form Choices]]: `Checkbox` / `Checkboxes` / `RadioButtons` / `BaseRadioButtons`
- [[Form YearMonthDay]]: composite date input; documents the Conform gotchas

For the current bundled inventory, query Serena (`.claude/rules/code-search.md`).

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

See [[Component Testing]] for the canonical example (`YearMonthDay/tests/`).

## Validation

- Use `parseWithZod(formData, {schema})` in actions
- Schemas live next to the component or as part of the action
- Server-side validation is the source of truth; client validation just provides UX

## Accessibility

GAIA's Form components handle label association automatically. For custom inputs, ensure `<label htmlFor>` or `aria-label`. See [[Accessibility]].
