/**
 * `gaia wiki state-bump <field> <value>` handler.
 *
 * Atomically updates one field in `wiki/.state.json`. Preserves sibling
 * fields and key order. The value is parsed as JSON when it parses
 * (numbers, booleans, null, arrays, objects); otherwise it is treated as a
 * raw string.
 *
 * Replaces the prose `jq ... > tmp && mv tmp wiki/.state.json` recipe in
 * `wiki/sync.md` Step 6 and `wiki/consolidate.md` Step 5.
 */
import {existsSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki state-bump <field> <value>

  Updates a single field in wiki/.state.json. Sibling fields and key order
  are preserved. <value> is parsed as JSON when it parses (numbers,
  booleans, null, arrays, objects); otherwise treated as a string.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const tryParseJson = (raw: string): unknown => {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
};

const reorderObject = (
  source: Record<string, unknown>,
  field: string,
  newValue: unknown
): Record<string, unknown> => {
  // Preserve insertion order of sibling fields. If `field` already exists,
  // overwrite in place (preserving its position). Otherwise append at end.
  const next: Record<string, unknown> = {};

  if (Object.hasOwn(source, field)) {
    for (const key of Object.keys(source)) {
      next[key] = key === field ? newValue : source[key];
    }

    return next;
  }

  for (const key of Object.keys(source)) {
    next[key] = source[key];
  }
  next[field] = newValue;

  return next;
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const positional: string[] = [];

  for (const token of argv) {
    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'wiki state-bump',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    positional.push(token);
  }

  if (positional.length !== 2) {
    structuredError({
      code: 'invalid_arguments',
      message: 'state-bump requires exactly <field> and <value>',
      subcommand: 'wiki state-bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const [field, valueRaw] = positional as [string, string];

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki state-bump must run inside a git repository',
      subcommand: 'wiki state-bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const statePath = path.join(repoRoot, 'wiki', '.state.json');

  if (!existsSync(statePath)) {
    structuredError({
      code: 'state_missing',
      message: 'wiki/.state.json does not exist',
      subcommand: 'wiki state-bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const raw = readFileSync(statePath, 'utf8');
  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    structuredError({
      code: 'state_malformed',
      message: 'wiki/.state.json is not valid JSON',
      subcommand: 'wiki state-bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    structuredError({
      code: 'state_malformed',
      message: 'wiki/.state.json must be a JSON object',
      subcommand: 'wiki state-bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const source = parsed as Record<string, unknown>;
  const next = reorderObject(source, field, tryParseJson(valueRaw));
  const trailingNewline = raw.endsWith('\n') ? '\n' : '';
  const serialized = `${JSON.stringify(next, null, 2)}${trailingNewline}`;
  const tmpPath = `${statePath}.tmp`;
  writeFileSync(tmpPath, serialized, 'utf8');
  renameSync(tmpPath, statePath);

  return EXIT_CODES.OK;
};
