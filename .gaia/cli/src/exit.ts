/**
 * Named exit codes for the gaia CLI. Hooks parse these to distinguish
 * structural drift (CLOUD_PROJECTION_DRIFT, PAYLOAD_VALIDATION_FAILED)
 * from operational failure (STORAGE_INACCESSIBLE, CONFIG_INVALID).
 *
 * Codes intentionally leave gaps so that future per-domain ranges
 * (telemetry: 10–19, storage: 20–29, config: 30–39) can extend without
 * renumbering.
 */
export const EXIT_CODES = {
  CLOUD_PROJECTION_DRIFT: 12,
  CONFIG_INVALID: 30,
  OK: 0,
  PAYLOAD_VALIDATION_FAILED: 11,
  STORAGE_INACCESSIBLE: 20,
  UNKNOWN_EVENT_TYPE: 10,
  UNKNOWN_SUBCOMMAND: 1,
} as const;

export type ExitCode = (typeof EXIT_CODES)[keyof typeof EXIT_CODES];
