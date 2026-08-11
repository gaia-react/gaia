/**
 * `gaia ci-stale-check` and `gaia ci-revert` are registered at the
 * top-level (`SUBCOMMAND_HANDLERS` in `index.ts`); `ci` is a namespace
 * prefix, not a sub-router.
 *
 * This module re-exports the two `run` handlers so the entrypoint can
 * import them with the existing `import {run as runCiX}` idiom.
 */
export {run as runCiRevert} from './revert.js';

export {run as runCiStaleCheck} from './stale-check.js';
