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
/* eslint-disable unicorn/no-process-exit -- this IS a CLI binary */
import {run as runFetchCoaching} from './adaptation/inject.js';
import {run as runAutomation} from './automation/index.js';
import {run as runCiRevert} from './ci/revert.js';
import {run as runCiStaleCheck} from './ci/stale-check.js';
import {EXIT_CODES} from './exit.js';
import {run as runInit} from './init/index.js';
import {run as runMentorship} from './mentorship/index.js';
import {run as runScaffold} from './scaffold/index.js';
import {run as runSetup} from './setup/index.js';
import {run as runSetupCi} from './setup-ci/index.js';
import {structuredError} from './stderr.js';
import {run as runTelemetry} from './telemetry/index.js';
import {run as runUpdate} from './update/index.js';
import {run as runUpdateDeps} from './update-deps/index.js';
import {run as runWiki} from './wiki/index.js';

const HELP_TEXT = `Usage: gaia <subcommand> [args]

  telemetry emit <event_type> [--field value ...]
  telemetry compute-profile
  mentorship enable|disable|purge|status
  mentorship analytics enable|disable|dry-run
  scaffold component|hook|route|service
  wiki state|commit-classify|state-init|state-bump|log-prepend|page-index|orphans|near-collisions|dead-paths|sync land
  automation read-config|read-state|init-state|bump-state|cron-decide|record-run|record-overage|clear-overage
  ci-stale-check --label <name> --base <branch> [--author <login>] [--json]
  ci-revert open|mark-failed|is-cap-reached
  update merge --baseline <dir> --latest <dir> --manifest <path>
  update-deps run --emit-updates <path>
  init strip-branding|configure-i18n|rename|wire-statusline|finalize|resume
  setup status|mark-step|finalize|link-worktree
  setup-ci status|detect-remote|warn-existing-tools|check-admin|dismiss-personal|opt-out-team|enable-delete-branch|set-secret|verify-run|finalize|write-tool-mode
`;

const printHelp = (): void => {
  process.stdout.write(HELP_TEXT);
};

type SubcommandHandler = (
  args: string[]
) => number | Promise<number | undefined> | undefined;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  automation: runAutomation,
  'ci-revert': runCiRevert,
  'ci-stale-check': runCiStaleCheck,
  init: runInit,
  mentorship: runMentorship,
  scaffold: runScaffold,
  setup: runSetup,
  'setup-ci': runSetupCi,
  telemetry: runTelemetry,
  update: runUpdate,
  'update-deps': runUpdateDeps,
  wiki: runWiki,
};

const main = async (): Promise<number> => {
  // process.argv[2] is undefined when no subcommand is supplied. Node's
  // typings model argv as `string[]` (no `noUncheckedIndexedAccess`),
  // so we coerce through unknown to express the runtime reality.
  const subcommand = process.argv[2] as string | undefined;
  const rest = process.argv.slice(3);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    printHelp();

    return EXIT_CODES.OK;
  }

  // Internal subcommand consumed by the `/gaia spec` skill (and future
  // dispatch-time callers) to fetch profile-driven coaching text. Wired
  // top-level rather than under `mentorship` because it's an
  // implementation detail consumed by skill scaffolding, not a
  // user-facing surface — kept out of the help text to match the
  // `mentorship _internal-*` precedent.
  if (subcommand === '_internal-fetch-coaching') {
    return runFetchCoaching(rest);
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({code: 'unknown_subcommand', subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

main()
  .then((exitCode) => {
    process.exit(exitCode);
  })
  .catch((error: unknown) => {
    structuredError({
      code: 'cli_internal_error',
      message: error instanceof Error ? error.message : String(error),
    });
    process.exit(EXIT_CODES.UNKNOWN_SUBCOMMAND);
  });
