---
type: decision
status: active
priority: 1
date: 2026-10-05
created: 2026-10-05
updated: 2026-10-05
tags: [decision, components, shadcn, styling, accessibility]
---

# Decision: shadcn Component Layer

GAIA's component layer is [[shadcn]]: Base UI primitives, the `base-nova` style, the `neutral` base color. The components are vendored into `frontend/app/components/ui/`, owned by the project, and refreshed with the shadcn CLI.

## What is decided

- **Every component with a shadcn equivalent is the ui component.** GAIA ships no parallel Button, Input, Select, Checkbox, radio or field wrapper.
- **Kept app-logic components compose ui components.** `ThemeSwitch`, `LanguageSelect`, `FormError`, `MaxLength`, `Document`, `MetaHydrated`, `Layout`, `ErrorStack` and `RootErrorBoundary` hold behavior shadcn does not supply (theme cookie, language, Conform wiring, dev-only stacks, document shell) and render ui components for their surfaces. They use role tokens only.
- **Forms are composed, not wrapped.** There is no GAIA form wrapper. A form is built from the ui `Field` parts and ui controls with Conform's props and ids applied directly (`getInputProps`, `getSelectProps`, `getTextareaProps`, `getCollectionProps`, `useInputControl`). The pattern lives in `frontend/.claude/skills/react-code/references/conform-forms.md`; see [[Form Components]].
- **Components are typed inline.** `type XProps = {...}` and `const X = ({...}: XProps) => ...`. GAIA has no `FC` or `FunctionComponent` convention, and lint bans importing either from `react` ([[gaia-lint]]).
- **The baseline stays a placeholder.** The token values are shadcn's neutral set, which the adopter replaces. [[Design System]] keeps `established: false`.

## The shipped ui set

`alert`, `button`, `checkbox`, `field`, `input`, `input-group`, `label`, `native-select`, `radio-group`, `separator`, `spinner`, `textarea`, `toast`.

A component outside this set (for example `button-group` or `badge`) is added with `pnpm shadcn add <name>`. The shipped set is whatever the project imports, so a ui file with no importer is deleted rather than carried.

The ui stories and tests live in `frontend/app/components/ui/tests/` and ship `owned`, like every other component's tests. They are GAIA-authored and fully linted.

Two replacements worth naming:

- **Button as a link.** Base UI sets `role="button"` on a non-native `render` target, so the link pattern is `<Button nativeButton={false} render={<Link to="..." role="link" />}>`. A disabled action renders a disabled Button, never a disabled link. There is no `LinkButton`.
- **Checkbox groups.** Every checkbox in a group shares the field's single name (`getCollectionProps`), so the form posts one repeated key. The schema needs `.min(1)` for an empty group to error. Conform's `type` attribute is stripped before spreading onto `ui/checkbox`, which is a Base UI root and does not take it.

## Toasts

`ui/toast` is shadcn's `toast` component, built on Base UI's Toast primitive. `notify` (`frontend/app/utils/notify.ts`) exposes `notify.error|info|success|warning(payload)`, each returning the toast id. It drives the ui `toast` manager and derives the id from an md5 of the payload, so a repeated payload updates the live toast instead of stacking a copy. The root layout and the Storybook `ToastDecorator` each render a bare `<Toaster />` from `~/components/ui/toast`. Placement, the visible-toast limit and styling are the component's stock behavior: bottom-right, at most three toasts visible, and errors told apart by a destructive icon alone. In development a payload's `stack` goes to the console rather than into the toast. See [[remix-toast]].

## Theme files

Token values live in `frontend/app/styles/theme.css` (`:root`, `.dark`, `color-scheme`), imported by `frontend/app/styles/tailwind.css`, which keeps `@theme inline` and the base layer. The split exists so `/update-gaia` can treat the token file as adopter-editable while GAIA keeps owning the plumbing. `components.json` names `tailwind.css` as its CSS file, not `theme.css`: naming `theme.css` degrades `@shadcn/lint`'s token discovery, because that file does not import Tailwind. `shadcn add` leaves both theme files untouched.

Rebranding means editing token values in `theme.css` or regenerating them with shadcn's theming tools. The role-token contract is `frontend/.claude/rules/tailwind.md`.

## Accessibility overrides

Stock shadcn neutral fails contrast in two tokens and, with its translucent focus ring, in focus visibility. Three tokens differ from stock, all accessibility fixes rather than design choices:

- `--destructive` (light): darkened so destructive text passes 4.5:1.
- `--muted-foreground` (light): darkened so muted text passes 4.5:1.
- `--ring` (both themes): `oklch(20% 0 0deg)` light, `oklch(92% 0 0deg)` dark. Stock `ring-ring/50` measured 1.54:1 (light) and 1.88:1 (dark) against `--background`.

Measured focus indicator contrast, the same for button, checkbox, input, native-select and radio-group:

| Theme | Surface    | Indicator    | Ratio  |
| ----- | ---------- | ------------ | ------ |
| Light | background | ring         | 3.45:1 |
| Light | card       | ring         | 3.45:1 |
| Light | input      | ring         | 3.27:1 |
| Dark  | background | ring         | 4.42:1 |
| Dark  | card       | ring         | 4.36:1 |
| Dark  | input      | border-ring  | 10.53:1 |

Toast icons measure at least 5.79:1 against the toast surface in both themes (error is the lowest; the other types measure above 17:1).

The Playwright axe scan covers every page and every story in light and dark, with the WCAG 2.1 tags `wcag2a`, `wcag2aa`, `wcag21a` and `wcag21aa`. There is no `wcag22aa` tag in the scan, so WCAG 2.2 target size (minimum) is not checked. That is a known ceiling of the tooling, not a pass.

## Vendored-ui policy

- **Byte-identical to the registry.** Each `frontend/app/components/ui/*.tsx` matches `pnpm shadcn add <name>` output `use client` directive placement varies with the order of adds, so a refresh runs the full add command in one invocation.
- **Refresh with the CLI.** `pnpm shadcn add <name> --overwrite` re-vendors a file. Never hand-edit a ui file.
- **Prettier and the house-style rules are off for `ui/*.tsx` only.** The `shadcn/vendored-ui` block in [[gaia-lint]] turns off `prettier/prettier`, `@stylistic/quotes`, `prefer-arrow-functions`, `import-x/consistent-type-specifier-style`, `canonical/export-specifier-newline`, `sonarjs/prefer-read-only-props`, `@typescript-eslint/array-type`, `@typescript-eslint/promise-function-async`, `@typescript-eslint/no-use-before-define`, `@typescript-eslint/naming-convention`, `no-underscore-dangle`, `no-null-render`, `unicorn/prevent-abbreviations`, `react/boolean-prop-naming`, the `perfectionist` sort rules, and the `better-tailwindcss` canonical and shorthand class rules, plus `shadcn/no-arbitrary-values`, `shadcn/no-inline-styles` and `shadcn/no-restyle`.
- **Eight rules that unedited shadcn source trips are also off there**, by maintainer decision: `@typescript-eslint/prefer-destructuring` (the toast re-exports namespace members), `@typescript-eslint/no-unnecessary-condition`, `eqeqeq`, `react/no-array-index-key`, `jsx-a11y/label-has-associated-control`, `jsx-a11y/click-events-have-key-events`, `jsx-a11y/no-noninteractive-element-interactions` and `shadcn/require-static-classes`. The `react` entry of the import ban is lifted too, because shadcn's `import * as React` is a namespace import the rule reports; every other import ban stays.
- **Correctness stays on.** `shadcn/no-raw-colors`, `react-hooks/*` and the remaining correctness rules apply to ui files.
- **`ui/tests/**` is fully linted.** The exemption never reaches the GAIA-authored stories and tests.
- **How the exemption was chosen.** The rule list was measured by linting unedited `shadcn add` output for GAIA's set, plus a wider registry sample GAIA does not ship (`dialog`, `dropdown-menu`, `combobox`, `slider`, `select`, `popover`, `sheet`, `tooltip`) so the exemption also covers what adopters typically add. The wider sample surfaced only house-style rules, no correctness rule. A correctness finding on a file added later is a real finding, not an exemption candidate; a new house-style rule firing on an added file means extending the vendored-ui block in `@gaia-react/lint`.
- **Path-scoped rule.** `frontend/.claude/rules/shadcn-ui.md` loads this policy for Claude when it touches `app/components/ui/**`.

## Local patches

None. Every vendored ui file is byte-identical to `pnpm shadcn add <name>` output, so a refresh with `--overwrite` loses nothing.

## Tooling facts

- **Three `cn` copies.** The app depends on `cn` 0.4.0. The shadcn CLI devDependency pulls its own `cn` (`^0.2.4`) and `@shadcn/lint` pulls `cn` 0.3.2 as a dev-only dependency. They coexist and none reaches the production bundle. Vendored ui files import `cn` from the `cn` package.
- **The `utils` alias is schema-required and unused.** `components.json` must name one, and `shadcn add` writes no utils file, so `app/utils/cn.ts` does not exist.
- **`no-restyle` is on everywhere outside ui.** `shadcn/no-restyle` is an error with `allow: ['layout']` for GAIA-owned files, and off for `ui/*.tsx`. No GAIA-owned file needed it disabled, so no fallback block exists.

## Distribution

`frontend/app/styles/theme.css` and `frontend/components.json` ship `shared`, so `/update-gaia` merges an adopter's token values and added ui components instead of overwriting them. GAIA-shipped `ui/<name>.tsx` files ship `owned`.

<!-- gaia:maintainer-only:start -->
The classes are set in `.gaia/cli/src/release/manifest.ts`.
<!-- gaia:maintainer-only:end -->

## Related

[[shadcn]], [[lucide-react]], [[gaia-lint]], [[Design System]], [[Form Components]], [[Tailwind]], [[GAIA Philosophy]].
