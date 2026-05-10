/**
 * gaia-maintainer CLI entrypoint (maintainer-only binary).
 *
 * Adopter-binary surface plus the maintainer-only `release` namespace.
 * Bundles to `.gaia/cli/gaia-maintainer`, which `.gaia/release-exclude`
 * strips from the adopter tarball. Adopters never see this binary or
 * any of its commands; only the GAIA template's own maintainer (and CI
 * jobs running on the maintainer's clone) invokes it.
 *
 * Mirrors `index.ts` deliberately: the dispatch loop is short enough
 * that a shared abstraction would obscure the contract more than it
 * would save lines. Anything added to either binary's surface should be
 * added here too unless it is intentionally adopter-only.
 */
/* eslint-disable unicorn/no-process-exit -- this IS a CLI binary */
import {run as runFetchCoaching} from './adaptation/inject.js';
import {run as runAutomation} from './automation/index.js';
import {EXIT_CODES} from './exit.js';
import {run as runInit} from './init/index.js';
import {run as runMentorship} from './mentorship/index.js';
import {run as runRelease} from './release/index.js';
import {run as runScaffold} from './scaffold/index.js';
import {run as runSetup} from './setup/index.js';
import {structuredError} from './stderr.js';
import {run as runTelemetry} from './telemetry/index.js';
import {run as runUpdate} from './update/index.js';
import {run as runUpdateDeps} from './update-deps/index.js';
import {run as runWiki} from './wiki/index.js';

const HELP_TEXT = `Usage: gaia-maintainer <subcommand> [args]

Maintainer-only binary. Adopters use 'gaia' (no release namespace).

  telemetry emit <event_type> [--field value ...]
  telemetry compute-profile
  mentorship enable|disable|purge|status
  mentorship analytics enable|disable|dry-run
  scaffold component|hook|route|service
  wiki state|commit-classify|state-init|state-bump|log-prepend|page-index|orphans|near-collisions|dead-paths|sync land
  automation read-config|read-state|init-state|bump-state|cron-decide|record-run|record-overage|clear-overage
  update merge --baseline <dir> --latest <dir> --manifest <path>
  update-deps run --emit-updates <path>
  release preflight|bump|changelog|scrub-wiki|manifest|scrub|runtime-deps|commit-and-tag
  init strip-branding|configure-i18n|rename|wire-statusline|finalize|resume
  setup status|mark-step|finalize|link-worktree
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
  init: runInit,
  mentorship: runMentorship,
  release: runRelease,
  scaffold: runScaffold,
  setup: runSetup,
  telemetry: runTelemetry,
  update: runUpdate,
  'update-deps': runUpdateDeps,
  wiki: runWiki,
};

const main = async (): Promise<number> => {
  const subcommand = process.argv[2] as string | undefined;
  const rest = process.argv.slice(3);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    printHelp();

    return EXIT_CODES.OK;
  }

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
