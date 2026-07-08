---
subagents: [typescript]
library: tailwind-merge
---

# tailwind-merge Audit Rules

- Import only from `tailwind-merge`, flag any use of `clsx`, `classnames`, or `cn` wrappers for class merging
- `twJoin` when no class conflict is possible (internal construction, no incoming `className` prop)
- `twMerge` when a consumer `className` prop or two conflict-eligible strings must merge
- Conditional classes: pass falsy values directly (`twJoin('base', isActive && 'bg-blue-500')`), flag template literals used to build class lists inline
- Variant/size lookup: multi-class strings in `Record<Variant, string>` constants, referenced positionally in `twJoin`/`twMerge`, not via template literal interpolation
- No arbitrary color values (`[#abc123]`), use palette tokens with opacity modifiers (`bg-blue-900/15`)
- No raw `px` values in class names, use Tailwind's spacing scale
- Tailwind v4: config lives in `app/styles/tailwind.css` under `@theme`/`@layer`/`@utility`, there is no `tailwind.config.ts`
