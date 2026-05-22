/**
 * `gaia-maintainer release scrub-wiki` handler.
 *
 * Steps 8 + 9 of the maintainer release runbook. Overwrites
 * `wiki/hot.md` and `wiki/log.md` with release-clean content. The exact
 * field reset list is codified verbatim from the runbook so adopters
 * who scaffold via `create-gaia` start from a consistent slate.
 *
 * No stdout on success. Exit 0 / 1 / 2.
 */
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia-maintainer release scrub-wiki [--version <X.Y.Z>] [--date <YYYY-MM-DD>]

  Overwrite wiki/hot.md and wiki/log.md with release-clean content
  (Step 8 + Step 9 of the runbook).

  Flags:
    --version <X.Y.Z>     Override the new version (default: package.json).
    --date <YYYY-MM-DD>   Override the release date (default: today UTC).

  Exit codes:
    0  success (no stdout)
    1  user-correctable error
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

type Flags = {
  date: string | undefined;
  version: string | undefined;
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
  let date: string | undefined;
  let version: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--version') {
      const taken = takeValue(argv, index + 1, '--version');

      if (!taken.ok) return taken;
      version = taken.value;
      index += 1;
      continue;
    }

    if (token === '--date') {
      const taken = takeValue(argv, index + 1, '--date');

      if (!taken.ok) return taken;
      date = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {date, version}, ok: true};
};

const todayUtc = (now: Date = new Date()): string => {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

const readVersion = (cwd: string, override: string | undefined): string => {
  if (override !== undefined && override.length > 0) return override;
  const target = path.join(cwd, 'package.json');

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const parsed = JSON.parse(readFileSync(target, 'utf8')) as {
    version?: unknown;
  };

  if (typeof parsed.version !== 'string') {
    throw new Error('package.json has no string "version"');
  }

  return parsed.version;
};

export const renderHotMd = (version: string, date: string): string =>
  `---
type: meta
title: Hot Cache
status: active
created: ${date}
updated: ${date}
tags: [meta, cache]
---

# Recent Context

## Last Updated

${date}. Released as GAIA v${version}. Fresh slate.

## Active Threads

- None.
`;

export const renderLogMd = (version: string, date: string): string =>
  `---
type: meta
title: Log
status: active
created: ${date}
updated: ${date}
tags: [meta, log]
---

# Log

## [v${version}] ${date} | Released

See CHANGELOG.md for details.
`;

type RunOptions = {
  cwd?: string;
  /** Override "today" for deterministic tests. */
  today?: string;
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
      subcommand: 'release scrub-wiki',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  let version: string;

  try {
    version = readVersion(cwd, parsed.flags.version);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub-wiki',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const date = parsed.flags.date ?? options.today ?? todayUtc();
  const wikiDir = path.join(cwd, 'wiki');

  if (!existsSync(wikiDir)) {
    structuredError({
      code: 'wiki_dir_missing',
      message: `wiki/ directory not found at ${wikiDir}`,
      subcommand: 'release scrub-wiki',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const hotPath = path.join(wikiDir, 'hot.md');
  const logPath = path.join(wikiDir, 'log.md');

  try {
    mkdirSync(wikiDir, {recursive: true});
    atomicWriteFileSync(hotPath, renderHotMd(version, date));
    atomicWriteFileSync(logPath, renderLogMd(version, date));
  } catch (error) {
    structuredError({
      code: 'scrub_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub-wiki',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
