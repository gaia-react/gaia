/**
 * `gaia ping` handler.
 *
 * Flat handler (no `SUBCOMMAND_HANDLERS` map): the single shared entry
 * point the `/gaia-init`, `/setup-gaia`, and `/update-gaia` skills call to
 * fire the adoption ping. Parses `--event <init|setup|update>`
 * plus the per-event field flags, then hands the payload to `postPing`
 * (`./send.ts`), which injects `projectId`/`gaiaVersion`/`platform` and is
 * itself fire-and-forget.
 *
 * Only argument-parsing failures return a non-zero exit code; the network
 * send is best-effort inside `postPing` and never affects the exit code.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {postPing} from './send.js';
import type {PingEvent, PingPayload} from './send.js';

const HELP_TEXT = String.raw`Usage: gaia ping --event <init|setup|update> [--field value ...]

  Send the shared adoption ping. Accepted fields depend on
  --event:

    init    --mode <interactive|automatic> --i18n <non-negative int> \
            --ci <ci|local|off|custom>
    setup   --type <init|clone|reconfigure> --mentorship <on|off> \
            --repo <create|adopt|manual> --ci <on|off|skip> \
            --audit <local|ci>
    update  --from <version> --to <version>

  All fields are individually optional; only provided fields are sent.
  Fire-and-forget: exit code reflects only arg-parsing errors, never the
  network call. Suppressed by GAIA_TELEMETRY_PING_DISABLE=1.

  Exit codes:
    0  success
    1  user-correctable error (missing/invalid flag)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const SUBCOMMAND = 'ping';

const PING_EVENTS = ['init', 'setup', 'update'] as const;

const isPingEvent = (value: string): value is PingEvent =>
  (PING_EVENTS as readonly string[]).includes(value);

type FieldSpec = {
  enumValues?: readonly string[];
  flag: string;
  key: string;
  numeric?: boolean;
};

const FIELDS_BY_EVENT: Readonly<Record<PingEvent, readonly FieldSpec[]>> = {
  init: [
    {enumValues: ['interactive', 'automatic'], flag: '--mode', key: 'mode'},
    {flag: '--i18n', key: 'i18n', numeric: true},
    {enumValues: ['ci', 'local', 'off', 'custom'], flag: '--ci', key: 'ci'},
  ],
  setup: [
    {
      enumValues: ['init', 'clone', 'reconfigure'],
      flag: '--type',
      key: 'type',
    },
    {enumValues: ['on', 'off'], flag: '--mentorship', key: 'mentorship'},
    {
      enumValues: ['create', 'adopt', 'manual'],
      flag: '--repo',
      key: 'repo',
    },
    {enumValues: ['on', 'off', 'skip'], flag: '--ci', key: 'ci'},
    {enumValues: ['local', 'ci'], flag: '--audit', key: 'audit'},
  ],
  update: [
    {flag: '--from', key: 'from'},
    {flag: '--to', key: 'to'},
  ],
};

const NON_NEGATIVE_INT_RE = /^\d+$/u;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as
  // `string`, not `string | undefined`; check the bound explicitly instead
  // of comparing the indexed value to `undefined`.
  if (index >= argv.length || argv[index].startsWith('--')) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

type ParseResult =
  {message: string; ok: false} | {ok: true; payload: PingPayload};

type TokenParseResult =
  | {event: PingEvent; ok: true; provided: Map<string, string>}
  | {message: string; ok: false};

const parseArgvTokens = (argv: readonly string[]): TokenParseResult => {
  let event: PingEvent | undefined;
  const provided = new Map<string, string>();

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--event') {
      const taken = takeValue(argv, index + 1, '--event');

      if (!taken.ok) return taken;

      if (!isPingEvent(taken.value)) {
        return {
          message: `--event must be one of: ${PING_EVENTS.join(', ')}`,
          ok: false,
        };
      }
      event = taken.value;
      index += 1;
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      provided.set(token, taken.value);
      index += 1;
    }
  }

  if (event === undefined) {
    return {message: '--event is required', ok: false};
  }

  return {event, ok: true, provided};
};

const buildPayloadForEvent = (
  event: PingEvent,
  provided: ReadonlyMap<string, string>
): ParseResult => {
  const specs = FIELDS_BY_EVENT[event];
  const payload: PingPayload = {event};

  for (const [flag, rawValue] of provided) {
    const spec = specs.find((candidate) => candidate.flag === flag);

    if (spec === undefined) {
      return {message: `unknown flag for event ${event}: ${flag}`, ok: false};
    }

    if (spec.enumValues !== undefined && !spec.enumValues.includes(rawValue)) {
      return {
        message: `${flag} must be one of: ${spec.enumValues.join(', ')}`,
        ok: false,
      };
    }

    if (spec.numeric) {
      if (!NON_NEGATIVE_INT_RE.test(rawValue)) {
        return {message: `${flag} must be a non-negative integer`, ok: false};
      }
      payload[spec.key] = Number(rawValue);
    } else {
      payload[spec.key] = rawValue;
    }
  }

  return {ok: true, payload};
};

const parsePing = (argv: readonly string[]): ParseResult => {
  const tokenResult = parseArgvTokens(argv);

  if (!tokenResult.ok) return tokenResult;

  return buildPayloadForEvent(tokenResult.event, tokenResult.provided);
};

type RunOptions = {
  cwd?: string;
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parsePing(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  await postPing(options.cwd ?? process.cwd(), parsed.payload);

  return EXIT_CODES.OK;
};
