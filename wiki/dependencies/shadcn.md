---
type: dependency
status: active
package: 'shadcn'
role: component-layer
created: 2026-10-05
updated: 2026-10-05
tags: [dependency, components, shadcn, styling]
---

# shadcn

The component layer GAIA vendors into `frontend/app/components/ui/`. The decision and its policies live in [[shadcn Component Layer]]; this page covers the packages involved.

## The CLI and registry

`shadcn` is a devDependency at an exact version. `pnpm shadcn add <name>` fetches a component from the shadcn registry and writes it to `frontend/app/components/ui/<name>.tsx`; `frontend/components.json` configures the style (`base-nova`), base color (`neutral`), icon library (`lucide`) and aliases. The output is vendored source the project owns, not an installed package. The CLI declares its own `cn` dependency, a separate copy from the app's.

## Runtime packages

- `@base-ui/react`: the unstyled primitives the ui components wrap (button, checkbox, radio group, and so on). Components accept a `render` prop to change the rendered element.
- `class-variance-authority`: `cva` variant tables inside vendored files and in kept GAIA components that expose variants.
- `tw-animate-css`: animation utilities the vendored classes use, imported in `frontend/app/styles/tailwind.css`.
- [[lucide-react]]: the icon set.
- `cn`: class composition and conflict merging; vendored files import it from this package.

`/update-deps` moves `shadcn`, `@base-ui/react`, `class-variance-authority`, `lucide-react` and `tw-animate-css` as one group.

## Token linting

`@shadcn/lint` is bundled into [[gaia-lint]] and enforces role tokens in source files. Its `cn` dependency is a third copy, dev-only.
