---
subagents: [typescript]
library: cn
---

# cn Audit Rules

- Compose classes only with `cn` imported as `import {cn} from 'cn';`. Flag any import from `tailwind-merge`, any `twMerge` or `twJoin` call (including `twMerge` or `twJoin` imported from `cn`), and any `clsx`, `classnames`, or local `cn` wrapper, re-export, or `app/utils` alias
- Conditional classes are written `cond && 'class'` (negated `!cond && 'class'`), with a two-class ternary for either/or. Flag an object conditional and a ternary with an empty branch (`undefined`, `null`, `false`, or `''`) anywhere in a `cn` call. The `cn-conditional/cn-conditional` rule in `@gaia-react/lint` already errors on both, so a finding here means lint was bypassed or disabled; flag any `eslint-disable` of that rule
- A caller `className` goes last so it overrides component defaults; flag a component that accepts `className` and does not pass it through `cn`
- Flag template literals used to build class lists inline
- Variant/size lookup: multi-class strings in `Record<Variant, string>` constants, referenced positionally in `cn`, not via template literal interpolation
- No arbitrary color values (`[#abc123]`), use palette tokens with opacity modifiers (`bg-blue-900/15`)
- No raw `px` values in class names, use Tailwind's spacing scale
- Tailwind v4: config lives in `app/styles/tailwind.css` under `@theme`/`@layer`/`@utility`, there is no `tailwind.config.ts`
