---
type: dependency
status: active
package: 'lucide-react'
role: icons
created: 2026-10-05
updated: 2026-10-05
tags: [dependency, icons]
---

# lucide-react

GAIA's only icon library. Each icon is a React component imported by name, tree-shaken per icon, and drawn as an inline `svg` with the class `lucide`. The shadcn registry's `iconLibrary` is `lucide` in `components.json`, so vendored ui files import from it too ([[shadcn]]).

## Usage

```tsx
import {Sun} from 'lucide-react';

<Sun aria-hidden={true} className="size-4" />;
```

- Size and color come from classes (`size-4`, `text-muted-foreground`), never inline styles. Color inherits `currentColor`, so a role token on the parent colors the icon.
- Decorative icons carry `aria-hidden`. An icon that is the only content of a control gets the name from the control's `aria-label`, not the icon.

## Render profiling

Each rendered icon produces two `ForwardRef` records in a [[React Perf Diagnostic]] capture: a wrapper named for the icon and an unnamed base `Icon`. The reduce step drops `ForwardRef` records as framework noise.

## Version pin

Exact-pinned in `frontend/package.json`; `/update-deps` moves it with the other component-layer packages as one group (see the `update-deps` skill).
