---
type: concept
status: active
established: false
created: 2026-06-28
updated: 2026-10-05
tags: [concept, design, styling]
---

# Design System

No design system is established. The current visual styling is a neutral baseline, not a decision about brand, palette, or typography.

## Current state

The token values in `frontend/app/styles/theme.css` are shadcn's neutral set, a placeholder the adopter replaces. They carry no brand hue and no opinion the adopter must keep. Nothing in the current styling implies a chosen visual language.

Three values differ from the stock neutral set: `--muted-foreground` and `--destructive` in the light theme, and `--ring` in both themes. These are accessibility fixes (text contrast and focus visibility), not brand choices; keep them when replacing the placeholder or re-measure. The measurements are in [[shadcn Component Layer]].

The contract for using tokens (role tokens only, and when a new one needs approval) lives in `frontend/.claude/rules/tailwind.md`. It permits adding a role token whose value equals an existing token or a value the code already repeats; a new color value asks first.

When an adopter establishes a real design system, they record their decisions here and flip `established` to `true` in this page's frontmatter. That sentinel is what `frontend/.claude/rules/design-baseline.md` keys its behavior off: while `established: false`, Claude treats every token value as open for adopter direction.

## Rebranding

Edit the token values in `frontend/app/styles/theme.css` (the `:root` and `.dark` blocks), or regenerate them with shadcn's theming tools. The components read role tokens, so every component follows.

## Page boundary

- **`wiki/modules/Styles.md`** owns Tailwind mechanics and token plumbing: how `@theme`, `@layer`, `@utility`, and the CSS variable pipeline are wired up.
- **This page** owns the adopter's chosen visual decisions: which palette, type scale, spacing system, and brand hue they select once they establish a design system.

## How to establish a design system

The implementation path -- Claude, a skill, a designer, a Figma handoff, a design token file -- does not matter. What matters is that once real brand decisions are made, this page gets updated. That update is what tells Claude the baseline is no longer in effect.

Required regardless of how the design was implemented:

1. Replace this page's body with the design system documentation (palette, typography, spacing, brand hue, and any other adopted conventions).
2. Flip `established: true` in this page's frontmatter.
3. Update `updated` in this page's frontmatter to today's date.
4. Ensure `frontend/app/styles/theme.css` reflects the chosen token values.

If Claude is the one implementing the design, it performs these updates automatically as part of the task. If the design is being implemented by other means, perform these updates manually before or immediately after the implementation lands.

Once `established: true`, `frontend/.claude/rules/design-baseline.md` defers to this page for all styling guidance.
