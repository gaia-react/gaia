---
paths:
  - 'app/components/**/*'
  - 'app/pages/**/*'
---

# Accessibility

## Core Requirements

- **Keyboard navigation**: all interactive elements must be reachable and operable via keyboard (Tab, Enter, Escape, Arrow keys)
- **Alt text**: all `<img>` elements need descriptive `alt` (or `alt=""` for decorative images)
- **Form labels**: form fields use the composed ui `Field` and Conform pattern (`Field`, `FieldLabel`, `FieldError` from `~/components/ui/field` around a ui control spreading Conform's props; see `frontend/.claude/skills/react-code/references/conform-forms.md`). A raw ui control carries no automatic label or error wiring, so every one needs a `FieldLabel` (or `aria-label`) and its error id
- **Color**: never use color as the sole indicator of meaning, add text or icons
- **Focus management**: when opening modals/dialogs, move focus into them; on close, return focus to trigger

## ARIA

- Prefer semantic HTML (`<button>`, `<nav>`, `<main>`) over ARIA roles
- Use `aria-label` when visible text is insufficient
- Use `aria-live="polite"` for dynamic content updates (toasts, status messages)
- Use `aria-expanded`, `aria-controls` for disclosure widgets

## Testing

- Tab through all interactive flows to verify keyboard operability
- Verify focus is visible on all focused elements: the indicator is the ring (`ring-ring` on the control, set to 3:1 contrast in both themes), so never remove it with `outline-none` unless a ring replaces it
- Check screen reader announcements for dynamic content
- Ensure no keyboard traps (user can always Tab away)
