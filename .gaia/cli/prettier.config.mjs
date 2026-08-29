/* eslint-disable canonical/filename-match-exported */
/*
 * Prettier config for the gaia CLI (@gaia-react/cli).
 *
 * The CLI's ESLint runs the `prettier/prettier` rule (from @gaia-react/lint's
 * prettier preset). eslint-plugin-prettier resolves the Prettier config by
 * walking up from each linted file, so without this file it would reach the
 * repo-root `prettier.config.mjs`, which imports `@gaia-react/lint` and only
 * resolves when the ROOT workspace is installed. The CI CLI-lint job installs
 * only `.gaia/cli` (`pnpm -C .gaia/cli install`), so the root import fails there
 * with ERR_MODULE_NOT_FOUND. Giving the CLI its own config stops the upward
 * search here and resolves `@gaia-react/lint` from `.gaia/cli/node_modules`,
 * keeping the CLI's Prettier rules identical to the root's.
 *
 * That preset names `prettier-plugin-tailwindcss` in its `plugins` array as a
 * bare specifier, and Prettier resolves a bare plugin specifier from the
 * process cwd rather than from the package that declared it. `pnpm -C .gaia/cli
 * lint` runs with cwd here, and pnpm's isolated layout gives a top-level
 * `.gaia/cli/node_modules` link only to a DIRECT dependency, so
 * `.gaia/cli/package.json` has to keep the plugin in `devDependencies`; the
 * copy `@gaia-react/lint` carries transitively is unreachable from this cwd.
 * Deleting it is the tempting simplification, because the root workspace
 * declares no such dependency and this file exists to mirror the root: it
 * passes every local check, where resolution escapes into the repo-root
 * `node_modules`, and fails the CI CLI-lint job, which installs `.gaia/cli`
 * alone, with ERR_MODULE_NOT_FOUND before a single file is linted.
 *
 * Its version tracks the one `@gaia-react/lint` pins, and no check enforces
 * that: `src/lint-pin-parity.test.ts` compares lockfile versions only for names
 * matching its `RULE_PACKAGE_PATTERN`, which this plugin's name does not match.
 * Move the two together whenever the `@gaia-react/lint` pin moves.
 */
import config from '@gaia-react/lint/prettier';

export default config;
