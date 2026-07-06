/* eslint-disable canonical/filename-match-exported */
/*
 * Prettier config for the gaia CLI (@gaia-react/cli).
 *
 * The CLI's ESLint runs the `prettier/prettier` rule (from @gaia-react/lint's
 * prettier preset). eslint-plugin-prettier resolves the Prettier config by
 * walking up from each linted file, so without this file it would reach the
 * repo-root `prettier.config.mjs` — which imports `@gaia-react/lint` and only
 * resolves when the ROOT workspace is installed. The CI CLI-lint job installs
 * only `.gaia/cli` (`pnpm -C .gaia/cli install`), so the root import fails there
 * with ERR_MODULE_NOT_FOUND. Giving the CLI its own config stops the upward
 * search here and resolves `@gaia-react/lint` from `.gaia/cli/node_modules`,
 * keeping the CLI's Prettier rules identical to the root's.
 */
import config from '@gaia-react/lint/prettier';

export default config;
