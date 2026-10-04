---
subagents: [react-patterns]
library: Form Components
---

# Form Component Gate

Use project form components instead of native elements in all `.tsx` files. Native form elements bypass the project's Conform integration and accessible error/label wiring.

| Native element                              | Use instead                                             |
| ------------------------------------------- | ------------------------------------------------------- |
| `<input type="text">`                       | `InputText` from `~/components/form/input-text`         |
| `<input type="email">`                      | `InputEmail` from `~/components/form/input-email`       |
| `<input type="password">`                   | `InputPassword` from `~/components/form/input-password` |
| `<input type="checkbox">` (single)          | `Checkbox` from `~/components/form/checkbox`            |
| `<input type="checkbox">` (group)           | `Checkboxes` from `~/components/form/checkboxes`        |
| `<input type="radio">` / radio group        | `RadioButtons` from `~/components/form/radio-buttons`   |
| `<select>`                                  | `Select` from `~/components/form/select`                |
| `<textarea>`                                | `TextArea` from `~/components/form/text-area`           |
| Date (year/month/day)                       | `YearMonthDay` from `~/components/form/year-month-day`  |
| Field wrapper (label + error + description) | `Field` from `~/components/form/field`                  |

Exceptions (native OK): `<input type="hidden">`, `<input type="file">`, `<input type="range">`.
