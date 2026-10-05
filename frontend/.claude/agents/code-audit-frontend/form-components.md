---
subagents: [react-patterns]
library: shadcn Form Fields
---

# Form Field Gate

GAIA has no form wrappers. A form field is composed from the ui `Field` parts, a ui control and Conform's props; the pattern and a code example per control type are in `frontend/.claude/skills/react-code/references/conform-forms.md`. A raw ui control carries no automatic label or error wiring, so the wiring must be written.

`components/ui/*.tsx` is vendored shadcn output and exempt from this gate; it is the building block, not a call site.

Flag, in every other `.tsx` file:

| Pattern                                                              | Use instead                                                                                   |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| native `<input>` (text types), `<textarea>`, `<select>`              | `Input`, `Textarea`, `NativeSelect` from `~/components/ui/...` inside a `Field`               |
| native `<input type="checkbox">` or `<input type="radio">`           | `Checkbox` or `RadioGroup` with `RadioGroupItem`; a group sits in a `FieldSet` with a `FieldLegend` |
| a ui control with no `FieldLabel htmlFor` (or `aria-label`)          | wrap it in `Field` with a `FieldLabel`                                                        |
| a `Field` without `data-invalid`, or a `FieldError` without `id={field.errorId}` | wire `data-invalid`, `field.id`, `field.errorId` and `field.descriptionId` as the reference shows |
| a disabled link standing in for a disabled action                    | a disabled `ui/button`                                                                        |

Exceptions (native OK): `<input type="hidden">`, `<input type="file">`, `<input type="range">`.
