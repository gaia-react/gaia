---
subagents: [typescript]
library: cn
---

# cn Audit Rules

- Compose classes only with `cn` imported as `import {cn} from 'cn';`. Flag any import from `tailwind-merge`, any `twMerge` or `twJoin` call (including `twMerge` or `twJoin` imported from `cn`), and any `clsx`, `classnames`, or local `cn` wrapper, re-export, or `app/utils` alias
- Conditional classes are written `cond && 'class'` (negated `!cond && 'class'`), with a two-class ternary for either/or. Flag an object conditional and a ternary with an empty branch (`undefined`, `null`, `false`, or `''`) anywhere in a `cn` call. The `cn-conditional/cn-conditional` rule in `@gaia-react/lint` already errors on both, so a finding here means lint was bypassed or disabled; flag any `eslint-disable` of that rule
- A caller `className` goes last so it overrides component defaults; flag a component that accepts `className` and does not pass it through `cn`
- Flag template literals used to build class lists inline
- Variants use `cva` from `class-variance-authority`: a component with a prop whose value selects a class string declares it in a `cva()` call, passed through `cn` with the caller's `className` last. Flag an object or `Record` whose values are Tailwind class strings keyed by a prop's values (typed or untyped), and a class-string lookup indexed into `cn`. Vendored `components/ui/*.tsx` is exempt (see the shadcn extension)
- Colors are theme role tokens only (`bg-background`, `text-muted-foreground`, `text-destructive`; the contract is `frontend/.claude/rules/tailwind.md`). Flag any raw palette class (a color name plus a shade, or `white` or `black`), an arbitrary color value in square brackets, a `dark:` color pair, and a removed legacy utility (the old `@utility` pairs and the `primary` shade ramp). A new color value with no token asks the adopter first; the tailwind skill owns when to create a role token
- No raw `px` values in class names, use Tailwind's spacing scale
- Tailwind v4: config lives in `app/styles/tailwind.css` under `@theme`/`@layer`/`@utility` with token values in `app/styles/theme.css`, there is no `tailwind.config.ts`
