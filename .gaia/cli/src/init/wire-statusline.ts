/**
 * `gaia init wire-statusline --mode <global|project|skip>` handler.
 *
 * Replaces the model-authored JSON-merge in Step 9 of `/gaia-init` with
 * a deterministic CLI write. Edits one of the two Claude settings files:
 *
 *   project   → `<cwd>/.claude/settings.json`
 *   global    → `<HOME>/.claude/settings.json`
 *   skip      → no-op (still records completion in init state)
 *
 * The merge inserts the canonical GAIA `statusLine` block at the top
 * level, preserving every existing key. If a `statusLine` is already
 * present and points at a non-GAIA command, it is overwritten; the
 * runbook's intent is "this project's statusline is GAIA's wrapper."
 *
 * Atomic writes: temp + rename. Stdout: nothing on success. Exit codes:
 * 0 / 1 / 2.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init wire-statusline --mode <global|project|skip>

  Wire the GAIA statusline into the relevant Claude settings file.

  Required flags:
    --mode <m>   "global" (~/.claude/settings.json), "project"
                 (.claude/settings.json), or "skip" (no-op).

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flag, invalid JSON in target)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'wire-statusline';

type Mode = 'global' | 'project' | 'skip';

const isMode = (value: string): value is Mode =>
  value === 'global' || value === 'project' || value === 'skip';

type Flags = {
  mode: Mode;
};

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let mode: Mode | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--mode') {
      const taken = takeValue(argv, index + 1, '--mode');

      if (!taken.ok) return taken;

      if (!isMode(taken.value)) {
        return {
          message: '--mode must be one of: global, project, skip',
          ok: false,
        };
      }
      mode = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (mode === undefined) {
    return {message: '--mode is required', ok: false};
  }

  return {flags: {mode}, ok: true};
};

/**
 * Canonical GAIA statusline block. The wrapper at
 * `.gaia/statusline/gaia-statusline.sh` lives at a project-relative path,
 * so the same `command` string is correct for both the project- and
 * global-scoped settings files (Claude resolves the bash invocation from
 * the project's working directory at startup).
 */
const STATUSLINE_BLOCK = {
  command: 'bash .gaia/statusline/gaia-statusline.sh',
  type: 'command',
} as const;

/**
 * Insert a single key into an object at the alphabetically-correct
 * position relative to existing keys. Preserves insertion order
 * everywhere else.
 */
const insertAlphabetical = (
  source: Record<string, unknown>,
  key: string,
  value: unknown
): Record<string, unknown> => {
  const next: Record<string, unknown> = {};
  let inserted = false;

  for (const existing of Object.keys(source)) {
    if (!inserted && existing > key) {
      next[key] = value;
      inserted = true;
    }

    if (existing === key) {
      // Skip; the new entry will overwrite at the alphabetical slot.
      continue;
    }
    next[existing] = source[existing];
  }

  if (!inserted) next[key] = value;

  return next;
};

const readSettings = (target: string): Record<string, unknown> => {
  if (!existsSync(target)) return {};
  const raw = readFileSync(target, 'utf8').trim();

  if (raw.length === 0) return {};
  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`${target} is not valid JSON`);
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${target} must be a JSON object`);
  }

  return parsed as Record<string, unknown>;
};

const writeSettings = (
  target: string,
  value: Record<string, unknown>
): void => {
  mkdirSync(path.dirname(target), {recursive: true});
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  const tmp = `${target}.tmp`;
  writeFileSync(tmp, serialized, 'utf8');
  renameSync(tmp, target);
};

const STATUSLINE_KEY = 'statusLine';

/**
 * Decides whether the existing block already matches the canonical GAIA
 * one. Used for idempotency.
 */
const matchesCanonical = (existing: unknown): boolean => {
  if (
    existing === null ||
    typeof existing !== 'object' ||
    Array.isArray(existing)
  ) {
    return false;
  }
  const candidate = existing as Record<string, unknown>;

  return (
    candidate.type === STATUSLINE_BLOCK.type &&
    candidate.command === STATUSLINE_BLOCK.command
  );
};

export const mergeStatusline = (
  source: Record<string, unknown>
): Record<string, unknown> => {
  if (matchesCanonical(source[STATUSLINE_KEY])) return source;

  return insertAlphabetical(source, STATUSLINE_KEY, {...STATUSLINE_BLOCK});
};

type RunOptions = {
  cwd?: string;
  /** Override `$HOME` for the global path. Test seam. */
  home?: string;
};

const targetPathForMode = (
  mode: Mode,
  cwd: string,
  home: string
): string | null => {
  if (mode === 'project') return path.join(cwd, '.claude', 'settings.json');

  if (mode === 'global') return path.join(home, '.claude', 'settings.json');

  return null;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'init wire-statusline',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const home = options.home ?? homedir();
  const target = targetPathForMode(parsed.flags.mode, cwd, home);

  if (target !== null) {
    try {
      const current = readSettings(target);
      const merged = mergeStatusline(current);
      writeSettings(target, merged);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);

      if (
        message.includes('not valid JSON') ||
        message.includes('JSON object')
      ) {
        structuredError({
          code: 'settings_malformed',
          message,
          subcommand: 'init wire-statusline',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      structuredError({
        code: 'wire_statusline_failed',
        message,
        subcommand: 'init wire-statusline',
      });

      return UNEXPECTED_EXIT;
    }
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {mode: parsed.flags.mode});
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init wire-statusline',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
