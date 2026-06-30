---
name: tailwind
description: Patterns and conventions for all Tailwind styling. Use this skill whenever writing Tailwind class names, combining conditional classes, building component variants, or choosing between twJoin and twMerge. Also trigger when the user asks about custom values, defining @theme tokens or CSS variables, naming color/spacing tokens, rem vs px, responsive breakpoints, or avoiding template literal class strings.
model: haiku
---

# Tailwind

## units

Always use Tailwind units first. For custom values, always use `rem`, never `px`.

```jsx
// BAD - tailwind units available but custom rem used
return <div className="p-[1.0625rem]" />;

// GOOD - uses tailwind units
return <div className="p-4.25" />;
```

## tailwind-merge

Use tailwind-merge to concatenate class names in React components instead of template literals or array joins.

- **`twJoin`**: for conditional class combinations (no override needed)
- **`twMerge`**: allow class override (merges conflicting utilities; perfect for setting default and optional classes)

### Examples

```tsx
import {twMerge, twJoin} from 'tailwind-merge';

// BAD, template literals with potential conflicts
return <span className={`bg-gray-500 ${isBlue ? 'bg-blue-500' : ''}`} />;

// GOOD - twJoin for conditional classes, but no override needed
return <span className={twJoin('bg-gray-800', isBlue && 'text-blue-500')} />;

// GOOD, twMerge for override, twJoin for conditional classes
return <span className={twMerge('text-white', isBlue && 'text-blue-500')} />;
```

The key distinction: use `twMerge` when a component accepts a `className` prop that should be able to override defaults, `twJoin` would leave both conflicting classes on the element, but `twMerge` resolves the conflict:

```tsx
// twMerge enables callers to override component defaults
function Button({className}: {className?: string}) {
  return (
    <button
      className={twMerge('bg-blue-500 px-4 py-2 text-white', className)}
    />
  );
}

// bg-red-500 wins, twMerge removes the conflicting bg-blue-500
<Button className="bg-red-500" />;
```

## Conditional classes

Pass falsy values directly to `twJoin` / `twMerge`, they're skipped.

```tsx
// correct
twJoin('base', isActive && 'bg-blue-500', error && 'border-red-500');

// ternaries that produce two positive values are fine
twJoin('base', condition ? 'a' : 'b');
```

Don't wrap class lists in template literals to concatenate, pass each class as a separate argument. Template literals inside `twJoin` / `twMerge` are acceptable **only** when interpolating a pre-built string from a lookup table (e.g., `ICON_POSITION[iconPosition]` from a `Record<string, string>`).

## Variant / size lookup tables

Extract multi-class variant strings into `Record` constants at the top of the file, then reference them positionally, not via interpolation.

```ts
const VARIANTS: Record<Variant, string> = {
  primary: 'border border-blue-400 bg-blue-500 text-white ...',
  secondary: '...',
};

// usage
twJoin('rounded-sm px-3 py-2', VARIANTS[variant]);
```

## Custom Values

When Tailwind's built-in scale doesn't have an exact value, use an arbitrary value with `rem`, never `px`:

```tsx
// BAD, px unit
<p className="text-[9px]" />

// GOOD, rem unit
<p className="text-[0.5625rem]" />
```

Use arbitrary values sparingly. If the same custom value appears more than once, add it to the tailwind.css `@theme` instead.

## Custom Theme Tokens

When adding `@theme` tokens to `app/styles/tailwind.css`, name them by **role**, not by the utility they'll be used with. The CSS variable suffix becomes the suffix on every generated utility (`bg-`, `text-`, `border-`, `ring-`, `fill-`, `stroke-`, `from-`, `to-`, etc.), so a token containing a utility prefix produces stuttering class names.

**Lint check before naming:** mentally expand `bg-{name}`, `text-{name}`, `border-{name}`. If any reads as a stutter or nonsense, rename.

```css
/* BAD, produces bg-bg, text-bg, border-bg-tint, text-text-muted */
--color-bg: #141413;
--color-bg-tint: #181c1e;
--color-text: #e0e0e0;
--color-text-muted: #999;

/* GOOD, produces bg-canvas, bg-surface, text-ink, text-muted */
--color-canvas: #141413;
--color-surface: #181c1e;
--color-ink: #e0e0e0;
--color-muted: #999;
```

Role vocabulary that survives the lint check: `canvas`, `surface`, `surface-raised`, `ink`, `muted`, `subtle`, `primary`, `brand-*`, `success`, `warning`, `danger`, palette-style names like `claude-500`. Avoid token names starting with `bg-`, `text-`, `border-`, `ring-`, `fill-`, `stroke-`, `from-`, `to-`, `outline-`, `shadow-`.

For paired light/dark colors, prefer defining an `@utility` (like the existing `bg-body`, `text-body`) over a single `@theme` token, `@utility` binds two palette values together; a `@theme` token exposes one hex on every utility prefix.
