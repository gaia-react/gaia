/* eslint-disable canonical/filename-match-exported */
/*
 * Prettier config for the gaia CLI (@gaia-react/cli).
 *
 * The CLI's ESLint runs the `prettier/prettier` rule (from @gaia-react/lint's
 * prettier preset). eslint-plugin-prettier resolves the Prettier config by
 * walking up from each linted file, so without this file it would reach the
 * repo-root `prettier.config.mjs`, which imports `@gaia-react/lint` and only
 * resolves when the root importer is installed. The CI CLI-lint job runs a root
 * install filtered to the CLI and its dependencies (the composite action's
 * `cli` arm), which links no root importer, so the root import fails there
 * with ERR_MODULE_NOT_FOUND. Giving the CLI its own config stops the upward
 * search here and resolves `@gaia-react/lint` from `.gaia/cli/node_modules`,
 * keeping the CLI's Prettier rules identical to the root's.
 *
 * That preset names `prettier-plugin-tailwindcss` in its `plugins` array as a
 * bare specifier, and Prettier resolves a bare plugin specifier from the
 * process cwd rather than from the package that declared it. `pnpm -C .gaia/cli
 * lint` runs with cwd here, and pnpm's isolated layout gives a top-level
 * `.gaia/cli/node_modules` link only to a DIRECT dependency, so the plugin
 * stays in `.gaia/cli/package.json`'s `devDependencies`; the copy
 * `@gaia-react/lint` carries transitively lands in `.pnpm/node_modules`, which
 * is not on Node's upward walk from this cwd. The root `pnpm-workspace.yaml`'s
 * `publicHoistPattern` covers `prettier-plugin-*` and now governs the CLI as a
 * workspace member, so the plugin is also hoisted into the repo-root
 * `node_modules`, even under the filtered install, and a walk up from here
 * would find it. The direct dependency stays as the mechanism that does not
 * rest on hoisting settings: it links the plugin into this directory
 * whatever the hoist pattern is.
 *
 * Deleting this file is the tempting simplification, because it exists to
 * mirror the root. Without it the upward search reaches the repo-root config,
 * and the filtered CI install has no root importer for that config's
 * `@gaia-react/lint` import to resolve through.
 * `eslint-plugin-prettier` loads Prettier lazily inside the rule, so the
 * ERR_MODULE_NOT_FOUND surfaces while ESLint is linting the first file and
 * reads as an ESLint crash rather than as a reported lint violation.
 *
 * Its version tracks the one `@gaia-react/lint` pins, because root declares no
 * version of its own and resolves the copy that preset depends on.
 */
import config from '@gaia-react/lint/prettier';

export default config;
