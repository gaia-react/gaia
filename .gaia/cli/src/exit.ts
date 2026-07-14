/**
 * Named exit codes for the gaia CLI. Hooks parse these to distinguish
 * payload/config validation failure (PAYLOAD_VALIDATION_FAILED,
 * CONFIG_INVALID) from operational failure (STORAGE_INACCESSIBLE).
 *
 * Codes intentionally leave gaps so that future per-domain ranges
 * (storage: 20–29, config: 30–39) can extend without renumbering.
 */
export const EXIT_CODES = {
  CONFIG_INVALID: 30,
  OK: 0,
  PAYLOAD_VALIDATION_FAILED: 11,
  STORAGE_INACCESSIBLE: 20,
  UNKNOWN_SUBCOMMAND: 1,
} as const;

export type ExitCode = (typeof EXIT_CODES)[keyof typeof EXIT_CODES];
