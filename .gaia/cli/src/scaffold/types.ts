/**
 * Shared types for the `gaia scaffold` subcommand family.
 *
 * `ScaffoldResult` is the canonical return shape from every scaffolder
 * (component, hook, route, service). When `--json` is passed, the handler
 * prints this structure as a single JSON line on stdout.
 */
export type ScaffoldResult = {
  /** Absolute paths to files newly created on disk. */
  written: string[];
  /** Absolute paths to files modified in place (barrel inserts, locale files, etc.). */
  edited: string[];
  /** Absolute paths to files that already existed with byte-identical contents. */
  skipped: string[];
};
