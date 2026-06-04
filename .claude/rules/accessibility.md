---
paths:
  - 'app/components/**/*'
  - 'app/pages/**/*'
---

# Accessibility

## Core Requirements

- **Keyboard navigation**: all interactive elements must be reachable and operable via keyboard (Tab, Enter, Escape, Arrow keys)
- **Alt text**: all `<img>` elements need descriptive `alt` (or `alt=""` for decorative images)
- **Form labels**: GAIA Form components (`app/components/Form/`) handle label association automatically. For custom inputs, ensure `<label htmlFor>` or `aria-label`
- **Color**: never use color as the sole indicator of meaning, add text or icons
- **Focus management**: when opening modals/dialogs, move focus into them; on close, return focus to trigger

## ARIA

- Prefer semantic HTML (`<button>`, `<nav>`, `<main>`) over ARIA roles
- Use `aria-label` when visible text is insufficient
- Use `aria-live="polite"` for dynamic content updates (toasts, status messages)
- Use `aria-expanded`, `aria-controls` for disclosure widgets

## Testing

- Tab through all interactive flows to verify keyboard operability
- Verify focus is visible (outline) on all focused elements
- Check screen reader announcements for dynamic content
- Ensure no keyboard traps (user can always Tab away)
