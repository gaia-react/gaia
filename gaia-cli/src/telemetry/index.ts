import {EXIT_CODES} from '../exit.js';
/**
 * `gaia telemetry` subcommand router.
 *
 * Phase 2 wires `emit`. Phase 5 wires `compute-profile` via
 * `gaia-cli/src/profile/index.ts` `computeProfile()`.
 */
import {computeProfile} from '../profile/index.js';
import {structuredError} from '../stderr.js';
import {handleEmit} from './emit.js';

const HELP_TEXT = `Usage: gaia telemetry <subcommand> [args]

  emit <event_type> [--field value ...]   Emit one telemetry event.
  compute-profile                          Regenerate profile.md from events.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * Entry point invoked by the top-level CLI router (`src/index.ts`).
 * Returns the process exit code; the top-level caller `process.exit`s.
 */
export const run = async (argv: readonly string[]): Promise<number> => {
  // `argv` is `readonly string[]`; without `noUncheckedIndexedAccess`, the
  // first element is typed `string` even when absent at runtime, so we
  // coerce through unknown to express the runtime reality.
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (subcommand === 'emit') {
    return handleEmit(rest);
  }

  if (subcommand === 'compute-profile') {
    return computeProfile();
  }

  structuredError({
    code: 'unknown_subcommand',
    subcommand: `telemetry ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
