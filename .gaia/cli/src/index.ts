/**
 * gaia CLI entrypoint (adopter binary).
 *
 * Top-level subcommand router. Maintainer-only namespaces (currently just
 * `release`) live in `index.maintainer.ts` and bundle to a separate
 * binary (`gaia-maintainer`) excluded from the adopter tarball by
 * `.gaia/release-exclude`. The adopter binary must not import any
 * maintainer-only handler, so esbuild tree-shakes their code out of this
 * bundle by construction.
 */

import {run as runFitness} from './fitness/index.js';
import {run as runHardenLedger} from './harden/ledger.js';
import {run as runHardenTally} from './harden/tally.js';
import {run as runInit} from './init/index.js';
import {run as runLabels} from './labels/index.js';
import {run as runPackages} from './packages/index.js';
import {run as runPing} from './ping/index.js';
import {run as runReactPerf} from './react-perf/index.js';
import {run as runResidueCursor} from './residue/cursor-cmd.js';
import {run as runResidueRecord} from './residue/record-cmd.js';
import {run as runResidueTally} from './residue/tally.js';
import {run as runSandbox} from './sandbox/index.js';
import {run as runScaffold} from './scaffold/index.js';
import {run as runSetupCi} from './setup-ci/index.js';
import {run as runSetup} from './setup/index.js';
import {run as runUpdateDeps} from './update-deps/index.js';
import {run as runUpdate} from './update/index.js';
import {createSubcommandRouter, runWhenInvokedDirectly} from './util/router.js';
import type {SubcommandHandler} from './util/router.js';
import {run as runWiki} from './wiki/index.js';

const HELP_TEXT = `Usage: gaia <subcommand> [args]

  scaffold component|hook|route|service
  react-perf reduce <raw.json> [--frame-budget-ms N]
  wiki state|commit-classify|state-init|state-bump|log-prepend|page-index|orphans|near-collisions|dead-paths|frontmatter|empty-sections|broken-links|chain
  fitness render-card [--cols N]
  labels docs|sync
  packages sync-settings [--check]
  harden-ledger list|record|prune|snapshot
  harden-tally
  update merge-workspace|merge-audit-ci|merge-region|regen-regions
  update-deps run|decline|global-tools|advisories|advisory-landed|dismiss-alert|write-security-cache|check-security-override
  init strip-branding|configure-i18n|configure-data-layer|rename|wire-statusline|bootstrap-env|write-project-config|finalize|resume
  setup status|mark-step|finalize
  setup-ci detect-remote|warn-existing-tools|check-admin|enable-delete-branch|write-isolation-policy|configure-dependabot-alerts
  sandbox detect|apply|record|status
  ping --event <init|setup|update> [--field value ...]
  residue-tally [--count-only] [--attribute-only] [--cap N] [--no-cap] [--json]
  residue-cursor advance --token T|clear
  residue-record --disposition dismissed|kept|suppressed --token T [--token T ...] --reason-file F
`;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  fitness: runFitness,
  'harden-ledger': runHardenLedger,
  'harden-tally': runHardenTally,
  init: runInit,
  labels: runLabels,
  packages: runPackages,
  ping: runPing,
  'react-perf': runReactPerf,
  'residue-cursor': runResidueCursor,
  'residue-record': runResidueRecord,
  'residue-tally': runResidueTally,
  sandbox: runSandbox,
  scaffold: runScaffold,
  setup: runSetup,
  'setup-ci': runSetupCi,
  update: runUpdate,
  'update-deps': runUpdateDeps,
  wiki: runWiki,
};

export const run = createSubcommandRouter({
  handlers: SUBCOMMAND_HANDLERS,
  helpText: HELP_TEXT,
});

await runWhenInvokedDirectly(import.meta.url, run);
