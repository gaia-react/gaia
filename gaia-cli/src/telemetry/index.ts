/**
 * `gaia telemetry` subcommand router.
 *
 * Phase 2 (this task) wires `emit`. `compute-profile` is provisioned as a
 * stub here so the top-level CLI router resolves the subcommand path; the
 * real implementation lands in Phase 5 (`task-compute-profile.md`).
 */
import {EXIT_CODES} from '../exit.js';
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
    structuredError({
      code: 'subcommand_not_implemented',
      message: 'compute-profile lands in SPEC-001 Phase 5',
      subcommand: 'telemetry compute-profile',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  structuredError({
    code: 'unknown_subcommand',
    subcommand: `telemetry ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
