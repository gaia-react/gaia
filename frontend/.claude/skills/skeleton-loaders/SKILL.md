---
name: skeleton-loaders
description: Builds skeleton loading states that are pixel-perfect matches of real content. Use this skill whenever adding loading states to components, building skeletons for async data, handling pending loader states in route transitions, or implementing the shimmer animation pattern. Also trigger when the user asks about preventing layout shift during data fetching.
model: haiku
---

# Skeleton Loaders

Build skeleton loading states that are pixel-perfect matches of real content.

## Transparent Text Technique

Use real HTML elements (`<p>`, `<span>`, `<h2>`, `<button>`) with the same font classes as the real component, plus shimmer + transparency classes. This makes skeletons inherit exact line-height, font-size, and weight, producing pixel-perfect dimensions without hardcoded `h-*`/`w-*` values.

### Define the shimmer animation once

`animate-shimmer` is not a built-in Tailwind utility. If `app/styles/tailwind.css` has no `--animate-shimmer`, add the token and its keyframes inside the existing `@theme` block before using the class (otherwise `better-tailwindcss/no-unknown-classes` fails lint):

```css
@theme {
  --animate-shimmer: shimmer 2s linear infinite;
  /* The gradient is 200% wide (bg-size-[200%_100%]); moving background-position from 100% to -100% shifts it one full tile, so the sweep loops seamlessly. */
  @keyframes shimmer {
    from {
      background-position: 100% 0;
    }
    to {
      background-position: -100% 0;
    }
  }
}
```

### Shimmer class constant

Define a shared class string at the top of the skeleton component:

```tsx
const shimmer =
  'animate-shimmer rounded-sm bg-linear-to-r from-muted via-accent to-muted bg-size-[200%_100%] text-transparent select-none';
```

### Text elements

Copy the real component's element type and font classes, add `shimmer`. How you fill the text depends on whether the real text is static or dynamic:

- **Static, translatable text** (labels, headings, button text): use the same `t()` value the real component uses. The text is transparent, but reusing `t()` makes the skeleton width match the revealed text exactly.
- **Dynamic runtime values** (`{data.name}`, API content): you cannot know the real value, so use hardcoded placeholder text of similar character count to approximate its width.

```tsx
import {cn} from 'cn';

// Real component
<h2 className="text-lg font-bold text-foreground">{t('profile.heading')}</h2>   // static
<p className="truncate text-sm font-semibold text-foreground">{data.name}</p>   // dynamic
<p className="text-xs text-muted-foreground">{data.value}</p>                     // dynamic

// Skeleton
<h2 className={cn('text-lg font-bold', shimmer)}>{t('profile.heading')}</h2>  // same t(), exact width
<p className={cn('truncate text-sm font-semibold', shimmer)}>Name</p>         // approximate
<p className={cn('text-xs', shimmer)}>Example value</p>                        // approximate
```

### Non-text elements (images, icons, avatars)

Keep as empty divs with the shimmer class, no text needed:

```tsx
<div className={cn('size-14 shrink-0', shimmer)} />
```

### Interactive elements (buttons)

Use the real element type with `tabIndex={-1}` to prevent focus. Button labels are static text, so use the real `t()` value (exact width on reveal):

```tsx
<button
  className={cn('w-full py-2 text-xs font-medium', shimmer)}
  tabIndex={-1}
  type="button"
>
  {t('common.submit')}
</button>
```

## 200ms Delay Pattern

Avoid skeleton flash on fast loads. Show stale/empty content for 200ms before revealing the skeleton:

```tsx
const [showSkeleton, setShowSkeleton] = useState(false);

// Valid Effect: synchronizing component state with a timer (external system).
// The cleanup prevents a state update after unmount.
useEffect(() => {
  const timer = setTimeout(() => setShowSkeleton(true), 200);
  return () => clearTimeout(timer);
}, []);

if (!showSkeleton) return null; // or return stale content
return <MySkeleton />;
```

## When to Use

- Lazy-loaded panels (side panels, detail views)
- Fetcher-driven content swaps
- Async data sections (lists, profiles, detail views)
- Route transitions with pending loader data

## Accessibility

Skeleton text is transparent, but screen readers still announce it (placeholder text and any `t()` labels). Hide the skeleton from assistive tech and announce loading instead:

- Put `aria-hidden` on the skeleton's root element so assistive tech skips the decorative placeholders.
- Mark the region that will receive the content with `aria-busy="true"` while loading, or render a visually-hidden `role="status"` "Loading" message so screen-reader users know content is on the way.

## Full Example Implementation

```tsx
import {cn} from 'cn';

const shimmer =
  'animate-shimmer rounded-sm bg-linear-to-r from-muted via-accent to-muted bg-size-[200%_100%] text-transparent select-none';

const ExampleSkeleton = () => (
  <div aria-hidden className="border border-border bg-card">
    <div className="flex items-center gap-3 p-3">
      <div className={cn('size-14 shrink-0', shimmer)} />
      <div className="min-w-0 flex-1">
        <p className={cn('truncate text-sm font-semibold', shimmer)}>
          Name
        </p>
        <p className={cn('truncate text-xs', shimmer)}>Example value</p>
      </div>
    </div>
  </div>
);

export default ExampleSkeleton;
```
