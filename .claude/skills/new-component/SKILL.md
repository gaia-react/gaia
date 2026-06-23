---
name: new-component
description: Scaffold a new React component with optional Storybook story and Vitest test files. Use this skill whenever the user asks to "create a component", "make a button", "scaffold a card", "add a new component", or asks for a new file under `app/components/` following the project's component pattern (PascalCase folder, index.tsx, tests/).
model: haiku
---

# new-component

Trigger: user asks to create a component, scaffold a card, etc.

## Workflow

1. Confirm with user via AskUserQuestion: name (PascalCase), parent dir (default `app/components`), props (or "none"), story (default yes).
2. Run: `.gaia/cli/gaia scaffold component <Name> [flags]`
3. Verify: `pnpm typecheck` clean. Open the new files, sanity-check the props.
4. If user wants more (variants, conditional rendering, complex children): edit the generated files. The skill does not regenerate.

## Flags

- `--no-story`, skip Storybook story
- `--parent <dir>`, non-default parent dir (e.g. `app/components/Form`)
- `--props "a:string,b:number"`, typed props rendered as a Props alias and destructured in the signature. Commas separate props, so comma-bearing types (`Record<K, V>`, `(a, b) => void`, tuples) are not supported; pass one `--props` flag per prop.

## Accessibility assertion

Scaffolded test files include a `test('a11y')` block that calls `expectNoA11yViolations` from `test/a11y.ts` (axe-core, full default ruleset, no tag filter). Because `axe-core` is incompatible with the project's default `happy-dom` test environment (`Node.prototype.isConnected` is getter-only, capricorn86/happy-dom#978), the scaffolder writes `// @vitest-environment jsdom` as the first line of the test file. The directive is required: `expectNoA11yViolations` throws an actionable error if it detects a non-jsdom runtime. Don't strip the directive when editing the file.

The a11y block renders a non-degenerate instance so it can fail against a real violation rather than passing vacuously against an empty DOM. With `--props`, the scaffolder fills representative values (`title="title"`, `count={0}`, …) at the render site (in the story `Default` when a story exists, otherwise inline in the test). Replace the placeholder values with realistic ones. The render-only axe pass is a starting point, not complete a11y evidence: add interaction-state and prop-variant assertions as the component grows.
