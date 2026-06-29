---
type: concept
status: active
established: false
created: 2026-06-28
updated: 2026-06-28
tags: [concept, design, styling]
---

# Design System

No design system is established. The current visual styling is a neutral baseline, not a decision about brand, palette, or typography.

## Current state

The token set in `app/styles/tailwind.css` (primary scale, font stacks, spacing, border-radius) is a deliberate blank slate. It carries no brand hue and no opinion the adopter must keep. Nothing in the current styling implies a chosen visual language.

When an adopter establishes a real design system, they record their decisions here and flip `established` to `true` in this page's frontmatter. That sentinel is what `.claude/rules/design-baseline.md` keys its behavior off: while `established: false`, Claude treats every token as open for adopter direction rather than something to extend.

## Page boundary

- **`wiki/modules/Styles.md`** owns Tailwind mechanics and token plumbing: how `@theme`, `@layer`, `@utility`, and the CSS variable pipeline are wired up.
- **This page** owns the adopter's chosen visual decisions: which palette, type scale, spacing system, and brand hue they select once they establish a design system.

## How to establish a design system

The implementation path -- Claude, a skill, a designer, a Figma handoff, a design token file -- does not matter. What matters is that once real brand decisions are made, this page gets updated. That update is what tells Claude the baseline is no longer in effect.

Required regardless of how the design was implemented:

1. Replace this page's body with the design system documentation (palette, typography, spacing, brand hue, and any other adopted conventions).
2. Flip `established: true` in this page's frontmatter.
3. Update `updated` in this page's frontmatter to today's date.
4. Ensure `app/styles/tailwind.css` reflects the chosen token values.

If Claude is the one implementing the design, it performs these updates automatically as part of the task. If the design is being implemented by other means, perform these updates manually before or immediately after the implementation lands.

Once `established: true`, `.claude/rules/design-baseline.md` defers to this page for all styling guidance.
