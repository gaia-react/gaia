---
subagents: [react-patterns, typescript]
library: shadcn/ui
---

# shadcn Audit Rules

GAIA's component layer is shadcn/ui (Base UI primitives, `base-nova` style). Policy: `frontend/.claude/rules/shadcn-ui.md` and `wiki/decisions/shadcn Component Layer.md`.

- **Registry first.** A new component that has a shadcn registry counterpart (dialog, tabs, popover, and so on) is added with `pnpm shadcn add <name>` and composed, not hand-written. Flag a hand-written component that duplicates a registry item
- **`components/ui/*.tsx` is vendored.** Each file is byte-identical to `pnpm shadcn add <name>` output at the pinned shadcn version. Flag any edit to one that is not a listed local patch. A listed patch carries a one-line header comment naming it and has an entry in the decision page's local-patch list; flag a patch missing either
- **Patches only.** Flag a diff to a vendored file that reformats it, adds a feature, restyles it or fixes a lint finding in it: the lint block exempts the vendored folder, so the fix belongs in `@gaia-react/lint`, not the file
- **`shadcn add --overwrite` drops a local patch.** Flag an overwrite of a patched file that does not re-apply its patch
- **Do not review vendored files for house style.** `function` declarations, `import * as React`, arbitrary values and unformatted code in `components/ui/*.tsx` are expected. Correctness findings still apply
- **Never a style reference.** Flag a GAIA component outside `components/ui/` that copies the vendored style (`function` declaration, `import * as React`, an arbitrary value) instead of GAIA's own conventions
- **Compose, do not restyle.** A GAIA component passes `className` for layout only; flag a `className` that restyles a ui part (color, border, radius, typography). Variants of a ui part come from the part's own `cva` props
- **ui stories and tests.** Every `components/ui/<name>.tsx` has `components/ui/tests/<name>.stories.tsx` rendering each variant value plus the invalid and disabled states. `ui/tests/` is fully linted and formatted
