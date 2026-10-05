---
name: new-component
description: Scaffold a new React component with its Storybook story, which is the component's test. Use this skill whenever the user asks to "create a component", "make a button", "scaffold a card", "add a new component", or asks for a new file under `app/components/` following the project's component pattern (kebab-case folder, index.tsx, tests/), or asks for a component a shadcn registry item already provides (dialog, tabs, popover, and so on).
model: haiku
---

# new-component

Trigger: user asks to create a component, scaffold a card, etc.

## Workflow

1. Registry check first. Before writing any component by hand, check whether shadcn has it: `pnpm shadcn view <name>` for a known item, or `pnpm shadcn search` (for example `pnpm shadcn search dialog`) to look. A registry counterpart means a button, dialog, tabs, popover, select, table and the like.
2. If the registry has it, run `pnpm shadcn add <name>`. The file lands flat in `app/components/ui/<name>.tsx` and is vendored: do not edit it (see `frontend/.claude/rules/shadcn-ui.md`). Then compose the added component in a GAIA component or page rather than hand-writing a replacement; add `app/components/ui/tests/<name>.stories.tsx` for the new ui file. Stop here unless the user still needs a GAIA component around it.
3. Only when the registry has no counterpart, or the request is app logic around ui parts: confirm with user via AskUserQuestion: name (PascalCase or kebab-case; the folder is kebab-case), parent dir (default `app/components`), props (or "none").
4. Run from the repo root: `./.gaia/cli/gaia scaffold component <Name> [flags]` (the package comes from the registry, not the working directory).
5. Verify: `pnpm typecheck` clean. Open the new files, sanity-check the props.
6. If user wants more (variants, conditional rendering, complex children): edit the generated files. The skill does not regenerate. Before hand-editing, read one or two existing components with a similar shape and follow their pattern; style with role tokens and `cva` for variants (`frontend/.claude/skills/tailwind/SKILL.md`).

## Adopter notes

- Registry hooks land in `~/hooks` as kebab-case `use-*.ts` files, which GAIA's layout accepts.
- The `utils` alias in `components.json` is required by the config schema but unused: registry files import `cn` from the `cn` package, so `shadcn add` writes no util file.

## Flags

- `--no-story` is refused (exit 1, nothing written): the story is the component's test, so a component cannot be scaffolded without one
- `--parent <dir>`, non-default parent dir, an existing `app/components[/...]` folder (e.g. `app/components/form`) or `app/pages/<path>` to colocate the component in a page folder. A parent equal to or under `app/components/ui`, or outside `app/components` and `app/pages`, is refused; the layout rule is in `frontend/.claude/rules/coding-guidelines-react.md`
- `--props "a:string,b:number"`, typed props rendered as a Props alias and destructured in the signature. Only top-level commas separate props, so comma-bearing types (`Record<K, V>`, `(a, b) => void`, tuples) are supported within a single entry.

## The story is the test

The scaffold writes `tests/index.stories.tsx` with a `Default` story, a `Renders` story and a play function on `Renders`, and no test file. Stories run as tests under `@storybook/addon-vitest` in headless Chromium (run `pnpm install:browsers` once), and addon-a11y axe-checks every story, so a story that renders a violation fails with no extra test. Import `expect`, `within` and `userEvent` from `storybook/test`.

With `--props`, the scaffolder fills representative values (`title="title"`, `count={0}`, ...) at the story's render site. Replace the placeholders with realistic ones. The scaffolded play is a starting point, not complete evidence: add a story with a play per behavior (interactions, state transitions, error paths) as the component grows, and for an interactive component assert a keyboard path and a focus outcome. How to write plays: `frontend/.claude/skills/tdd-react/references/tests-react.md`.
