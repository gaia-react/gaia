---
name: new-component
description: Scaffold a new React component with optional Storybook story and Vitest test files. Use this skill whenever the user asks to "create a component", "make a button", "scaffold a card", "add a new component", or asks for a new file under `app/components/` following the project's component pattern (PascalCase folder, index.tsx, tests/).
model: haiku
---

# new-component

Trigger: user asks to create a component, scaffold a card, etc.

## Workflow

1. Confirm with user via AskUserQuestion: name (PascalCase), parent dir (default `app/components`), props (or "none"), story (default yes).
2. Run: `gaia scaffold component <Name> [flags]`
3. Verify: `pnpm typecheck` clean. Open the new files, sanity-check the props.
4. If user wants more (variants, conditional rendering, complex children): edit the generated files. The skill does not regenerate.

## Flags

- `--no-story` — skip Storybook story
- `--parent <dir>` — non-default parent dir (e.g. `app/components/Form`)
- `--props "a:string,b:number"` — typed props rendered as a Props alias and destructured in the signature
