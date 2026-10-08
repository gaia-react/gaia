---
name: tailwind
description: Applies GAIA's patterns and conventions for all Tailwind styling. Use this skill whenever writing Tailwind class names, combining classes with `cn`, writing conditional classes, or building component variants. Also trigger when the user asks about custom values, defining @theme tokens or CSS variables, naming color/spacing tokens, rem vs px, responsive breakpoints, or avoiding template literal class strings.
---

# Tailwind

## units

Always use Tailwind units first. Custom values are a last resort (see Custom Values) and always `rem`, never `px`.

```jsx
// BAD - tailwind units available but custom rem used
return <div className="p-[1.0625rem]" />;

// GOOD - uses tailwind units
return <div className="p-4.25" />;
```

## Colors

Every color is a theme role token (`bg-background`, `text-foreground`, `text-muted-foreground`, `bg-primary`, `text-primary-foreground`, `border-input`, `text-destructive`), never a raw palette class or an arbitrary color. The contract and where the token list lives: `frontend/.claude/rules/tailwind.md`. The light and dark values live in the token, so write one utility, not a `dark:` pair.

```tsx
// BAD, raw palette classes and a dark: pair
return <p className="bg-white text-gray-900 dark:bg-gray-900 dark:text-white" />;

// GOOD, role tokens carry both themes
return <p className="bg-background text-foreground" />;
```

## cn

`cn` is the only class utility. Use it to combine class names in React components instead of template literals or array joins.

```tsx
import {cn} from 'cn';
```

`cn` joins its arguments and merges conflicting utilities, so a component default can be overridden by a caller. Put the caller's `className` last: the later class wins on conflict.

```tsx
import {cn} from 'cn';

// BAD, template literals with potential conflicts
return <span className={`bg-muted ${isActive ? 'bg-accent' : ''}`} />;

// GOOD, cn skips falsy values and resolves conflicts
return <span className={cn('text-foreground', isActive && 'bg-accent')} />;

// GOOD, callers can override component defaults
const Badge = ({className}: {className?: string}) => (
  <span className={cn('bg-muted px-4 py-2 text-foreground', className)} />
);

// bg-accent wins, cn removes the conflicting bg-muted
<Badge className="bg-accent" />;
```

## Conditional classes

Write a conditional class as `cond && 'class'`, and `!cond && 'class'` when negated. Falsy values are skipped.

```tsx
// correct
cn('base', isActive && 'bg-accent', !isDisabled && 'hover:bg-muted');

// a ternary with two class values is fine for either/or
cn('base', condition ? 'text-foreground' : 'text-muted-foreground');
```

Lint rejects object conditionals and ternaries with an empty branch passed to `cn` (`cn-conditional/cn-conditional` from `@gaia-react/lint`), in components, tests, and stories alike. Use `cond && 'class'` instead.

Don't wrap class lists in template literals to concatenate, pass each class as a separate argument.

## Variants with cva

A component has variants when a prop's value selects a class string. Declare them with `cva` from `class-variance-authority` at the top of the file, then pass the result through `cn` with the caller's `className` last. Never write an object or `Record` whose values are Tailwind class strings keyed by a prop, and never index one into `cn`.

```tsx
import {cva} from 'class-variance-authority';
import {cn} from 'cn';

const statusVariants = cva('rounded-md px-2 py-1 text-sm', {
  defaultVariants: {tone: 'neutral'},
  variants: {
    tone: {
      danger: 'bg-destructive text-primary-foreground',
      neutral: 'bg-muted text-muted-foreground',
    },
  },
});

type StatusProps = {
  className?: string;
  tone?: 'danger' | 'neutral';
};

const Status = ({className, tone}: StatusProps) => (
  <span className={cn(statusVariants({tone}), className)} />
);
```

Boolean variants key on `true` and `false`. For the variant prop's type, `VariantProps<typeof statusVariants>` keeps it in sync with the cva call. Vendored `components/ui/*.tsx` files already use cva this way; they are not a style reference for GAIA's own components (`frontend/.claude/rules/shadcn-ui.md`).

## Custom Values

Prefer Tailwind's spacing scale (`p-4.25`, `min-w-9`). Arbitrary values are rejected by lint (`shadcn/no-arbitrary-values`) outside the vendored ui folder. When no scale value fits, round to the nearest scale step, or add a token to `app/styles/tailwind.css` `@theme` when the same custom value appears more than once. Never use `px`.

```tsx
// BAD, arbitrary px value
<p className="text-[9px]" />

// GOOD, scale value
<p className="text-xs" />
```

## When to create a role token

This section is the single owner of token-creation guidance; the rules, wiki and audit files point here.

1. **Use an existing token first.** Search the `:root` and `.dark` blocks in `app/styles/theme.css`. Most needs are covered (`muted`, `accent`, `destructive`, `border`, `input`, `ring`).
2. **A token equal to an existing value needs no approval.** Adding a role token whose value equals an existing token, or a value the code already repeats in more than one place, just names a role that already exists. Add it to both blocks of `theme.css` and map it in the `@theme inline` block of `tailwind.css`.
3. **A new color value asks first.** Introducing a value the theme does not already contain is a design decision: ask the adopter, and while `wiki/concepts/Design System.md` has `established: false`, follow `frontend/.claude/rules/design-baseline.md`.
4. **Never a raw class for a one-off.** If a color has no token, it needs one (rules 2 or 3), not a raw palette class or an arbitrary color at the call site.

### Naming a token

Name tokens by **role**, not by the utility they will be used with. The CSS variable suffix becomes the suffix on every generated utility (`bg-`, `text-`, `border-`, `ring-`, `fill-`, `stroke-`, `from-`, `to-`, etc.), so a token containing a utility prefix produces stuttering class names.

**Lint check before naming:** mentally expand `bg-{name}`, `text-{name}`, `border-{name}`. If any reads as a stutter or nonsense, rename.

```css
/* BAD, produces bg-bg, text-bg, border-bg-tint, text-text-muted */
--color-bg: #141413;
--color-bg-tint: #181c1e;
--color-text: #e0e0e0;
--color-text-muted: #999;

/* GOOD, produces bg-canvas, bg-surface, text-ink, text-muted */
--color-canvas: oklch(20% 0 0deg);
--color-surface: oklch(25% 0 0deg);
--color-ink: oklch(90% 0 0deg);
--color-muted: oklch(65% 0 0deg);
```

Avoid token names starting with `bg-`, `text-`, `border-`, `ring-`, `fill-`, `stroke-`, `from-`, `to-`, `outline-`, `shadow-`. A token has a light value in `:root` and a dark value in `.dark`, so a pair never needs a custom `@utility`.
