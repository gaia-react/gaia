---
type: dependency
status: active
package: 'react-icons'
version: 5.5.0
role: icons
created: 2026-05-01
updated: 2026-05-01
tags: [dependency, icons]
---

# react-icons

Icon library providing thousands of icons as React components. GAIA uses `react-icons/io5` (Ionicons 5) for UI icons and `react-icons/fa6` (Font Awesome 6) for brand icons.

## Usage

Icons are React components. Pass them via the `IconType` type from `react-icons`:

```tsx
import type {IconType} from 'react-icons';
import {IoSearch} from 'react-icons/io5';

// In component props
interface Props {
  icon?: IconType;
}

// Rendering
const Icon = icon;
<Icon className="h-4 w-4" />;
```

## Icon sets used

| Package           | Purpose                                       | Example                                      |
| ----------------- | --------------------------------------------- | -------------------------------------------- |
| `react-icons/io5` | UI icons (search, close, info, warning, etc.) | `IoSearch`, `IoClose`, `IoInformationCircle` |
| `react-icons/fa6` | Brand icons (GitHub, etc.)                    | `FaGithub`                                   |

## Why react-icons

Single package, zero CSS injection, tree-shakeable per icon, consistent React component API across all icon families.

## Alternatives

[Heroicons](https://heroicons.com/), [Feather](https://feathericons.com/), Lucide.
