/**
 * `gaia update-deps decline` handler.
 *
 * Records (snoozes) update groups the human skipped in the interactive
 * `/update-deps` preview, so the statusline nudge stops counting them. Reads
 * the emitted updates payload (`run --emit-updates`) to resolve each skipped
 * name to its whole companion group and snapshot the group's current target
 * versions, then writes `.gaia/local/declined-updates.json` (full-replace).
 *
 * `--clear` empties the ledger (used when the human chose "update all"). The
 * snooze is local-statusline only and gitignored; CI never reads it.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {collectOutstandingGroups, saveDeclines} from './declines.js';
import type {CountablePayload, DeclinedRecord} from './declines.js';
import {resolveGroup} from './groups.js';

const HELP_TEXT = `Usage: gaia update-deps decline [options]

  Snooze update groups so the statusline stops counting them until a newer
  version ships or the 14-day cap elapses. Writes
  .gaia/local/declined-updates.json (gitignored; local statusline only).

  --source <path>   Emitted updates payload (from \`run --emit-updates\`).
                    Required with --skip.
  --skip <a,b,...>  Comma-separated package or group names to snooze. Each name
                    expands to its whole companion group.
  --clear           Clear the ledger (snooze nothing). Used on "update all".
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type DeclineOptions = {
  cwd?: string;
  now?: () => Date;
};

type ParsedArgs =
  {clear: false; skip: readonly string[]; source: string} | {clear: true};

type ParseError = {error: string};

const parseArgs = (argv: readonly string[]): ParsedArgs | ParseError => {
  let source: string | undefined;
  let skipRaw: string | undefined;
  let clear = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--clear') {
      clear = true;
      continue;
    }

    if (token === '--source') {
      const value = argv[index + 1];

      if (value === undefined || value.length === 0) {
        return {error: '--source requires a path'};
      }
      source = value;
      index += 1;
      continue;
    }

    if (token === '--skip') {
      const value = argv[index + 1];

      if (value === undefined) {
        return {error: '--skip requires a comma-separated list'};
      }
      skipRaw = value;
      index += 1;
      continue;
    }

    return {error: `unknown flag: ${token ?? ''}`};
  }

  if (clear) return {clear: true};

  if (source === undefined) return {error: '--source is required with --skip'};

  if (skipRaw === undefined) {
    return {error: '--skip is required (or use --clear)'};
  }

  const skip = skipRaw
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name.length > 0);

  if (skip.length === 0) return {error: '--skip listed no package names'};

  return {clear: false, skip, source};
};

const readPayload = (
  cwd: string,
  source: string
): CountablePayload | undefined => {
  const sourcePath = path.isAbsolute(source) ? source : path.join(cwd, source);

  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(sourcePath, 'utf8'));
  } catch {
    return undefined;
  }

  if (parsed === null || typeof parsed !== 'object') return undefined;

  const obj = parsed as Partial<CountablePayload>;

  if (!Array.isArray(obj.wave_a) || !Array.isArray(obj.wave_b)) {
    return undefined;
  }

  return {wave_a: obj.wave_a, wave_b: obj.wave_b};
};

export const run = (
  argv: readonly string[],
  options: DeclineOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'update-deps decline',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const now = (options.now ?? (() => new Date()))();

  if (parsed.clear) {
    saveDeclines(cwd, []);
    process.stdout.write(`${JSON.stringify({cleared: true})}\n`);

    return EXIT_CODES.OK;
  }

  const payload = readPayload(cwd, parsed.source);

  if (payload === undefined) {
    structuredError({
      code: 'source_unreadable',
      message: `cannot read updates payload: ${parsed.source}`,
      subcommand: 'update-deps decline',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const outstanding = collectOutstandingGroups(payload);
  const declinedAt = now.toISOString();
  const records: DeclinedRecord[] = [];

  for (const name of parsed.skip) {
    // Accept either a group id (e.g. `react-router`) or any member package
    // name; both resolve to the same group, which is snoozed as one unit.
    const group = outstanding.has(name) ? name : resolveGroup(name);
    const targets = outstanding.get(group);

    if (targets === undefined) {
      structuredError({
        code: 'unknown_package',
        message: `not an outstanding update: ${name}`,
        subcommand: 'update-deps decline',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (!records.some((record) => record.group === group)) {
      records.push({declined_at: declinedAt, group, targets});
    }
  }

  saveDeclines(cwd, records);
  process.stdout.write(
    `${JSON.stringify({
      declined_at: declinedAt,
      snoozed: records.map((record) => record.group),
    })}\n`
  );

  return EXIT_CODES.OK;
};
