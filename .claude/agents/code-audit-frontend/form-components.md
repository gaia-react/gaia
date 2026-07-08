---
subagents: [react-patterns]
library: GAIA Form Components
---

# GAIA Form Component Gate

Use project form components instead of native elements in all `.tsx` files. Native form elements bypass GAIA's Conform integration and accessible error/label wiring.

| Native element                              | Use instead                                            |
| ------------------------------------------- | ------------------------------------------------------ |
| `<input type="text">`                       | `InputText` from `~/components/Form/InputText`         |
| `<input type="email">`                      | `InputEmail` from `~/components/Form/InputEmail`       |
| `<input type="password">`                   | `InputPassword` from `~/components/Form/InputPassword` |
| `<input type="checkbox">` (single)          | `Checkbox` from `~/components/Form/Checkbox`           |
| `<input type="checkbox">` (group)           | `Checkboxes` from `~/components/Form/Checkboxes`       |
| `<input type="radio">` / radio group        | `RadioButtons` from `~/components/Form/RadioButtons`   |
| `<select>`                                  | `Select` from `~/components/Form/Select`               |
| `<textarea>`                                | `TextArea` from `~/components/Form/TextArea`           |
| Date (year/month/day)                       | `YearMonthDay` from `~/components/Form/YearMonthDay`   |
| Field wrapper (label + error + description) | `Field` from `~/components/Form/Field`                 |

Exceptions (native OK): `<input type="hidden">`, `<input type="file">`, `<input type="range">`.
