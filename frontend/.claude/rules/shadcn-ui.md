---
paths:
  - 'app/components/ui/**'
---

# Vendored shadcn ui

- `ui/*.tsx` is vendored shadcn output, byte-identical to `pnpm shadcn add <name>`. Refresh a file with that command.
- Never use a `ui/*.tsx` file as a style reference for components outside `ui/`: it uses `function` declarations, `import * as React` and arbitrary values that GAIA's own code does not.
- Edit a vendored file only as a listed local patch: a one-line header comment in the file plus an entry in the local-patch list of `wiki/decisions/shadcn Component Layer.md`. `shadcn add --overwrite` drops a patch, so re-apply it.
- Prettier and the house-style lint rules skip `ui/*.tsx`; correctness rules and the shadcn token rules still apply.
- The exemption was measured on GAIA's component set plus a wider sample of registry items. A new house-style rule firing on an added file means extending the vendored-ui block in `@gaia-react/lint`, not editing the file.
- `ui/tests/` is GAIA-authored and follows house style, fully linted and formatted.
