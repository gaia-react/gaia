/**
 * `gaia update-deps write-security-cache --count <n> --source <source>
 * [--reason <tokens>]` handler.
 *
 * Rewrites the update-check cache's three security fields and `checkedAt`
 * after a /update-deps report, so the statusline does not wait for the TTL.
 * Every other field is carried verbatim. The write takes the same lock
 * `check-updates.sh` holds while it refreshes, and releases it only while this
 * process still owns it.
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {resolveMainWorktreeRoot} from '../util/main-root.js';
import {ADVISORY_REASON_TOKENS} from './advisory-reasons.js';

const HELP_TEXT = `Usage: gaia update-deps write-security-cache --count <n> --source <dependabot|pnpm-audit> [--reason <tokens>]

  Rewrite securityCount, securitySource, securityUnavailableReason, and
  checkedAt in the main checkout's update-check cache, leaving every other
  field untouched. --count is a non-negative integer. --reason is a
  comma-joined list of unavailable-reason tokens. No cache file is a no-op.
  Prints {"written": true|false, ...} as JSON. Exit 0 written or no-op, 1 on
  an unreadable cache, 2 on a usage error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND = 'update-deps write-security-cache';

const SOURCES = new Set(['dependabot', 'pnpm-audit']);
const COUNT_PATTERN = /^\d+$/u;
const DEFAULT_LOCK_WAIT_MS = 10_000;
const LOCK_POLL_MS = 50;

const REASON_TOKENS: ReadonlySet<string> = new Set(ADVISORY_REASON_TOKENS);

export type WriteSecurityCacheOptions = {
  cwd?: string;
  /** How long to wait for a held lock before giving up. */
  lockWaitMs?: number;
  now?: () => Date;
  resolveMainRoot?: (cwd: string) => string;
};

type ParsedArgs = {count: number; reason: string; source: string};

const printResult = (result: Record<string, unknown>): void => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let count: string | undefined;
  let source: string | undefined;
  let reason = '';

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== '--count' && token !== '--source' && token !== '--reason') {
      return {error: `unknown flag: ${String(token)}`};
    }

    const value = argv[index + 1];

    if (value === undefined) return {error: `${token} requires a value`};

    if (token === '--count') count = value;
    else if (token === '--source') source = value;
    else reason = value;
    index += 1;
  }

  if (count === undefined || !COUNT_PATTERN.test(count)) {
    return {error: '--count must be a non-negative integer'};
  }

  const countNumber = Number(count);

  if (!Number.isSafeInteger(countNumber)) {
    return {error: '--count must be a non-negative integer'};
  }

  if (source === undefined || !SOURCES.has(source)) {
    return {error: '--source must be dependabot or pnpm-audit'};
  }

  if (
    reason.length > 0 &&
    !reason.split(',').every((token) => REASON_TOKENS.has(token))
  ) {
    return {error: '--reason must be comma-joined unavailable-reason tokens'};
  }

  return {count: countNumber, reason, source};
};

const sleepSync = (milliseconds: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
};

/** True once this process owns the lock, false when the budget ran out. */
const acquireLock = (lockDirectory: string, budgetMs: number): boolean => {
  const deadline = Date.now() + budgetMs;

  for (;;) {
    try {
      mkdirSync(lockDirectory);
      writeFileSync(path.join(lockDirectory, 'owner'), `${process.pid}\n`);

      return true;
    } catch {
      if (Date.now() >= deadline) return false;
      sleepSync(LOCK_POLL_MS);
    }
  }
};

const releaseLock = (lockDirectory: string): void => {
  try {
    const owner = readFileSync(path.join(lockDirectory, 'owner'), 'utf8');

    if (owner.trim() === String(process.pid)) {
      rmSync(lockDirectory, {force: true, recursive: true});
    }
  } catch {
    // The lock is already gone or was never ours: nothing to release.
  }
};

const readCache = (cacheFile: string): null | Record<string, unknown> => {
  try {
    const parsed: unknown = JSON.parse(readFileSync(cacheFile, 'utf8'));

    if (
      typeof parsed !== 'object' ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      return null;
    }

    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
};

export const run = (
  argv: readonly string[],
  options: WriteSecurityCacheOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const args = parseArgs(argv);

  if ('error' in args) {
    structuredError({
      code: 'invalid_arguments',
      message: args.error,
      subcommand: SUBCOMMAND,
    });
    printResult({reason: 'invalid-arguments', written: false});

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const cwd = options.cwd ?? process.cwd();
  let root: string;

  try {
    root = (options.resolveMainRoot ?? resolveMainWorktreeRoot)(cwd);
  } catch {
    root = cwd;
  }

  const cacheDirectory = path.join(root, '.gaia/local/cache/shared');
  const cacheFile = path.join(cacheDirectory, 'update-check.json');

  if (!existsSync(cacheFile)) {
    printResult({reason: 'no-cache', written: false});

    return EXIT_CODES.OK;
  }

  const lockDirectory = path.join(cacheDirectory, '.update-check.lock');

  if (!acquireLock(lockDirectory, options.lockWaitMs ?? DEFAULT_LOCK_WAIT_MS)) {
    printResult({reason: 'lock-held', written: false});

    return EXIT_CODES.OK;
  }

  try {
    const cache = readCache(cacheFile);

    if (cache === null) {
      printResult({reason: 'unreadable-cache', written: false});

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    const now = (options.now ?? (() => new Date()))();

    cache.securityCount = args.count;
    cache.securitySource = args.source;
    cache.securityUnavailableReason = args.reason;
    cache.checkedAt = Math.floor(now.getTime() / 1000);

    atomicWriteFileSync(cacheFile, `${JSON.stringify(cache)}\n`);
    printResult({written: true});

    return EXIT_CODES.OK;
  } finally {
    releaseLock(lockDirectory);
  }
};
