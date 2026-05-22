/**
 * `gaia init finalize` handler.
 *
 * Codifies the cleanup that closes Step 12 of `/gaia-init`:
 *
 *   1. Delete `.claude/hooks/intercept-init.sh` (no longer needed once the
 *      template's curated CLAUDE.md has been initialized).
 *   2. Strip the matching entry from `.claude/settings.json`'s
 *      `hooks.UserPromptExpansion` array; if the array is left empty,
 *      remove the `UserPromptExpansion` key entirely.
 *   3. Delete `.claude/commands/gaia-init.md` so the command cannot be
 *      run a second time.
 *
 * `pnpm install` is intentionally NOT performed here — it is a side
 * effect handled by the orchestrating skill before the CLI runs.
 *
 * Idempotent: re-running is safe — already-deleted files stay gone, the
 * settings prune is a no-op once the entry is removed.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init finalize

  Final cleanup steps for /gaia-init: remove the init interceptor hook,
  prune its settings entry, and delete the gaia-init.md command file.

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (settings malformed)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'finalize';

const INTERCEPT_HOOK = '.claude/hooks/intercept-init.sh';
const INIT_COMMAND = '.claude/commands/gaia-init.md';
const SETTINGS_FILE = '.claude/settings.json';

const removeIfPresent = (cwd: string, relative: string): void => {
  const absolute = path.join(cwd, relative);

  if (existsSync(absolute)) {
    rmSync(absolute, {force: true, recursive: true});
  }
};

type HookEntry = {
  hooks?: Array<{command?: unknown}> | unknown;
  matcher?: unknown;
};

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/**
 * Returns true when the inner `hooks` array contains a command entry
 * pointing at the intercept-init script. The runbook's contract is to
 * remove only matchers whose inner command matches — preserving any
 * other entries the user may have added.
 */
const matchesInterceptInit = (entry: unknown): boolean => {
  if (!isPlainObject(entry)) return false;
  const inner = (entry as HookEntry).hooks;

  if (!Array.isArray(inner)) return false;

  return inner.some(
    (hook) =>
      isPlainObject(hook) &&
      typeof (hook as Record<string, unknown>).command === 'string' &&
      ((hook as Record<string, unknown>).command as string).includes(
        'intercept-init.sh'
      )
  );
};

export const pruneInterceptInit = (
  source: Record<string, unknown>
): Record<string, unknown> => {
  const hooks = source.hooks;

  if (!isPlainObject(hooks)) return source;
  const expansion = hooks.UserPromptExpansion;

  if (!Array.isArray(expansion)) return source;

  const filtered = expansion.filter((entry) => !matchesInterceptInit(entry));

  if (filtered.length === expansion.length) return source;

  const nextHooks: Record<string, unknown> = {};

  for (const key of Object.keys(hooks)) {
    if (key === 'UserPromptExpansion') {
      if (filtered.length > 0) nextHooks[key] = filtered;
      continue;
    }
    nextHooks[key] = hooks[key];
  }

  const next: Record<string, unknown> = {};

  for (const key of Object.keys(source)) {
    next[key] = key === 'hooks' ? nextHooks : source[key];
  }

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

  if (!isPlainObject(parsed)) {
    throw new Error(`${target} must be a JSON object`);
  }

  return parsed;
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

const pruneSettings = (cwd: string): void => {
  const target = path.join(cwd, SETTINGS_FILE);

  if (!existsSync(target)) return;
  const current = readSettings(target);
  const next = pruneInterceptInit(current);

  if (next === current) return;
  writeSettings(target, next);
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  // No flags — but reject any tokens to keep the surface small.
  if (argv.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${argv[0] as string}`,
      subcommand: 'init finalize',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  try {
    pruneSettings(cwd);
    removeIfPresent(cwd, INTERCEPT_HOOK);
    removeIfPresent(cwd, INIT_COMMAND);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (message.includes('not valid JSON') || message.includes('JSON object')) {
      structuredError({
        code: 'settings_malformed',
        message,
        subcommand: 'init finalize',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    structuredError({
      code: 'finalize_failed',
      message,
      subcommand: 'init finalize',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME);
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init finalize',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
