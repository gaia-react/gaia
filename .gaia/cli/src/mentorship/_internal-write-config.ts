/**
 * Internal subcommand consumed by gaia-init's slash-command flow.
 *
 * Locked subcommand name:
 *
 *   gaia mentorship _internal-write-config \
 *     --enabled <bool> --analytics <bool> --decided-via <enum>
 *
 * Stamps `decided_at` to the current ISO-8601 UTC ms timestamp via the
 * underlying `writeMentorshipConfig`.
 */
import {EXIT_CODES} from '../exit.js';
import type {MentorshipConfig} from '../schemas/mentorship-config.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {writeMentorshipConfig} from './config.js';
import {installDisplayRule, removeDisplayRule} from './display-rule-memory.js';

const DECIDED_VIA_VALUES = [
  'gaia-init',
  'mentorship-analytics-disable',
  'mentorship-analytics-enable',
  'mentorship-disable',
  'mentorship-enable',
] as const;

type DecidedVia = NonNullable<MentorshipConfig['decided_via']>;

const isDecidedVia = (raw: string): raw is DecidedVia =>
  (DECIDED_VIA_VALUES as readonly string[]).includes(raw);

const parseBoolean = (raw: string | undefined): boolean | undefined => {
  if (raw === 'true') return true;

  if (raw === 'false') return false;

  return undefined;
};

type ParsedFlags = {
  analytics?: boolean;
  decidedVia?: string;
  enabled?: boolean;
};

const parseFlags = (argv: readonly string[]): ParsedFlags => {
  const flags: ParsedFlags = {};
  let index = 0;

  while (index < argv.length) {
    const token = argv[index] as string | undefined;
    const value = argv[index + 1] as string | undefined;

    if (token === '--enabled') {
      flags.enabled = parseBoolean(value);
      index += 2;
    } else if (token === '--analytics') {
      flags.analytics = parseBoolean(value);
      index += 2;
    } else if (token === '--decided-via') {
      flags.decidedVia = value;
      index += 2;
    } else {
      index += 1;
    }
  }

  return flags;
};

type RunOptions = {
  roots?: StorageRoots;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const flags = parseFlags(argv);

  if (flags.enabled === undefined) {
    structuredError({
      code: 'arg_parse_error',
      issue: '--enabled <true|false> is required',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  if (flags.analytics === undefined) {
    structuredError({
      code: 'arg_parse_error',
      issue: '--analytics <true|false> is required',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  if (flags.decidedVia === undefined || !isDecidedVia(flags.decidedVia)) {
    structuredError({
      code: 'arg_parse_error',
      issue: `--decided-via must be one of ${DECIDED_VIA_VALUES.join(', ')}`,
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }
  const roots = options.roots ?? resolveStorageRoots();

  try {
    writeMentorshipConfig({
      analyticsEnabled: flags.analytics,
      decidedVia: flags.decidedVia,
      enabled: flags.enabled,
      roots,
    });
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  // Project the mentorship-display rule into per-machine user memory.
  // gaia-init calls this subcommand with both enabled=true and enabled=false
  // outcomes — install on opt-in, remove on opt-out so the rule never
  // wastes context tokens for users who declined mentorship.
  try {
    if (flags.enabled) {
      installDisplayRule(roots);
    } else {
      removeDisplayRule(roots);
    }
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.memoryDir,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }
  process.stdout.write(
    `${JSON.stringify({
      analytics_enabled: flags.analytics,
      at: new Date().toISOString(),
      code: 'mentorship_config_written',
      decided_via: flags.decidedVia,
      enabled: flags.enabled,
    })}\n`
  );

  return EXIT_CODES.OK;
};
