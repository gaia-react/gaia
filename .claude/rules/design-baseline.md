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

## When Claude is implementing design decisions

If the adopter directs Claude to make styling changes that represent real brand decisions -- a chosen palette, a brand hue replacing the neutral primary scale, a specific type stack -- treat updating `wiki/concepts/Design System.md` as part of the same task:

1. Document the decisions in the wiki page body (what was chosen and why, replacing the placeholder prose).
2. Flip `established: true` in the wiki frontmatter.
3. Update `updated` in the wiki frontmatter to today's date.

Do this regardless of how the design was arrived at: Figma handoff, verbal direction, a style guide, a design token file. The wiki update is part of completing the task, not a separate follow-up.

If design decisions are being implemented without Claude's involvement (a designer editing files directly, a skill running autonomously, etc.), Claude cannot act. In that case `wiki/concepts/Design System.md` carries instructions for the adopter to perform the update manually.

## Why this rule exists

A coherent token set, even a deliberately neutral one, can be read by a code assistant as a signal that the palette and type stack are decided. They are not. Extending them without adopter direction would silently lock in an unintended aesthetic.
