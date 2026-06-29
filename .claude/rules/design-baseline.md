---
paths:
  - 'app/styles/**'
  - 'app/components/**'
  - 'app/pages/**'
  - 'app/routes/**'
---

# Design Baseline (Neutral, Not a Design System)

The current visual styling in `app/styles/`, `app/components/`, `app/pages/`, and `app/routes/` is a **deliberate neutral baseline**. It carries no brand hue and no opinion the adopter must follow. It is not a chosen design system.

## Behavioral switch

`wiki/concepts/Design System.md` carries a machine-readable sentinel in its frontmatter:

```
established: false
```

**While `established: false`:**

- Treat all tokens (primary scale, font stack, spacing, radius) as a blank slate.
- Do not infer or extend a "house style" from the neutral ramp.
- Do not invent palettes, type scales, or color pairings based on the existing values.
- When a styling question arises, ask the adopter what they want rather than extrapolating from the current tokens.

**Once an adopter records a real design system** (`established: true` in `wiki/concepts/Design System.md`), read that page for their chosen decisions and follow it instead.

## Why this rule exists

A coherent token set, even a deliberately neutral one, can be read by a code assistant as a signal that the palette and type stack are decided. They are not. The zero-chroma primary scale, system font stacks, and neutral radius values are starting-point blanks, not brand choices. Extending them without adopter direction would silently lock in an unintended aesthetic.
