/**
 * gaia-maintainer CLI entrypoint (maintainer-only binary).
 *
 * Release-only binary. Bundles to `.gaia/cli/gaia-maintainer`, which
 * `.gaia/release-exclude` strips from the adopter tarball. Adopters never
 * see this binary or any of its commands; only the GAIA template's own
 * maintainer (and CI jobs running on the maintainer's clone) invokes it.
 */

import {run as runRelease} from './release/index.js';
import {createSubcommandRouter, runWhenInvokedDirectly} from './util/router.js';
import type {SubcommandHandler} from './util/router.js';

const HELP_TEXT = `Usage: gaia-maintainer <subcommand> [args]

Maintainer-only binary. Adopters use 'gaia' (no release namespace).

  release preflight|bump|changelog|scrub-wiki|manifest|scrub|runtime-deps|commit-and-tag|exclude-regex
`;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  release: runRelease,
};

export const run = createSubcommandRouter({
  handlers: SUBCOMMAND_HANDLERS,
  helpText: HELP_TEXT,
});

await runWhenInvokedDirectly(import.meta.url, run);
