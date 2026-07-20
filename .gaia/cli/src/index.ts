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

import {realpathSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {run as runAutomation} from './automation/index.js';
import {run as runCiCheckSubject} from './ci/check-subject.js';
import {run as runCiRevert} from './ci/revert.js';
import {run as runCiStaleCheck} from './ci/stale-check.js';
import {EXIT_CODES} from './exit.js';
import {run as runFitness} from './fitness/index.js';
import {run as runHardenLedger} from './harden/ledger.js';
import {run as runHardenTally} from './harden/tally.js';
import {run as runInit} from './init/index.js';
import {run as runPing} from './ping/index.js';
import {run as runReactPerf} from './react-perf/index.js';
import {run as runSandbox} from './sandbox/index.js';
import {run as runScaffold} from './scaffold/index.js';
import {run as runSetupCi} from './setup-ci/index.js';
import {run as runSetup} from './setup/index.js';
import {structuredError} from './stderr.js';
import {run as runUpdateDeps} from './update-deps/index.js';
import {run as runUpdate} from './update/index.js';
import {run as runWiki} from './wiki/index.js';

const HELP_TEXT = `Usage: gaia <subcommand> [args]

  scaffold component|hook|route|service
  react-perf reduce <raw.json> [--frame-budget-ms N]
  wiki state|commit-classify|state-init|state-bump|log-prepend|page-index|orphans|near-collisions|dead-paths|sync land
  fitness render-card [--cols N]
  harden-ledger list|record|is-suppressed|prune
  harden-tally
  automation read-config|cron-decide
  ci-check-subject --subject "<text>"
  ci-stale-check --label <name> --base <branch> [--author <login>] [--json]
  ci-revert open|mark-failed|is-cap-reached
  update merge-workspace --baseline <file> --latest <file> --current <file>
  update-deps run --emit-updates <path>
  init strip-branding|configure-i18n|rename|wire-statusline|finalize|resume
  setup status|mark-step|finalize|link-worktree
  setup-ci status|detect-remote|warn-existing-tools|check-admin|dismiss-personal|opt-out-team|enable-delete-branch|verify-run|finalize|write-tool-mode
  sandbox detect|seed|apply|record|status
  ping --event <init|setup|update> [--field value ...]
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

type SubcommandHandler = (
  args: string[]
) => number | Promise<number | undefined> | undefined;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  automation: runAutomation,
  'ci-check-subject': runCiCheckSubject,
  'ci-revert': runCiRevert,
  'ci-stale-check': runCiStaleCheck,
  fitness: runFitness,
  'harden-ledger': runHardenLedger,
  'harden-tally': runHardenTally,
  init: runInit,
  ping: runPing,
  'react-perf': runReactPerf,
  sandbox: runSandbox,
  scaffold: runScaffold,
  setup: runSetup,
  'setup-ci': runSetupCi,
  update: runUpdate,
  'update-deps': runUpdateDeps,
  wiki: runWiki,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  // argv[0] is undefined when no subcommand is supplied. Node's typings
  // model argv as `string[]` (no `noUncheckedIndexedAccess`), so we cast
  // to express the runtime reality.
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    printHelp();

    return EXIT_CODES.OK;
  }

  // Own-property lookup. A bare `Record` index resolves every `Object.prototype`
  // member, so `gaia toString` would otherwise be accepted as a valid
  // subcommand and exit 0 without running anything.
  const handler =
    Object.hasOwn(SUBCOMMAND_HANDLERS, subcommand) ?
      SUBCOMMAND_HANDLERS[subcommand]
    : undefined;

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({code: 'unknown_subcommand', subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

// Auto-execute only when invoked directly as the bundled binary, not when a
// test imports this module. Both binaries are invoked by explicit path
// (`node .gaia/cli/gaia ...`), so argv[1] is this file; a test runner's
// argv[1] is vitest, so the guard is false and no process.exit fires.
const invokedPath = process.argv[1] as string | undefined;
const isDirectRun =
  invokedPath !== undefined &&
  import.meta.url === pathToFileURL(realpathSync(invokedPath)).href;

if (isDirectRun) {
  // Set `process.exitCode` and let the event loop drain rather than calling
  // `process.exit()`. `process.stdout` is asynchronous when it is a pipe, so
  // an immediate `process.exit()` discards whatever is still buffered: a
  // `wiki commit-classify --json` over a non-trivial range truncated at
  // exactly 65536 bytes (the pipe capacity) and handed its caller unparseable
  // JSON, while the same command redirected to a file wrote all of it. The
  // sync playbook reads that command through a pipe.
  try {
    process.exitCode = await run(process.argv.slice(2));
  } catch (error: unknown) {
    structuredError({
      code: 'cli_internal_error',
      message: error instanceof Error ? error.message : String(error),
    });
    process.exitCode = EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
}
