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
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';

const HELP_TEXT = `Usage: gaia-maintainer release scrub-wiki [--version <X.Y.Z>] [--date <YYYY-MM-DD>] [--check]

  Overwrite wiki/hot.md and wiki/log.md with release-clean content
  (Step 8 + Step 9 of the runbook).

  Flags:
    --version <X.Y.Z>     Override the new version (default: package.json).
    --date <YYYY-MM-DD>   Override the release date (default: today UTC).
    --check               Verify the committed wiki/hot.md and wiki/log.md
                          match freshly-rendered release-clean output and exit
                          non-zero on drift. Writes nothing. Dates are
                          normalized out of the comparison; the release gate
                          uses this to catch a wiki that was never scrubbed.

  Exit codes:
    0  success (no stdout); --check: no drift
    1  user-correctable error; --check: committed wiki file is stale or missing
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type Flags = {
  check: boolean;
  date: string | undefined;
  version: string | undefined;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `.at()` (unlike bracket indexing) types its result `string | undefined`,
  // which honestly reflects that `index` can run past the end of argv.
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let check = false;
  let date: string | undefined;
  let version: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--version') {
      const taken = takeValue(argv, index + 1, '--version');

      if (!taken.ok) return taken;
      version = taken.value;
      index += 1;
    } else if (token === '--date') {
      const taken = takeValue(argv, index + 1, '--date');

      if (!taken.ok) return taken;
      date = taken.value;
      index += 1;
    } else if (token === '--check') {
      check = true;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {check, date, version}, ok: true};
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
    throw new TypeError('package.json has no string "version"');
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

// The rendered templates embed the day the scrub ran, which is
// non-deterministic relative to when the release CI later verifies them (the
// tag can be pushed a day after the scrub commit). `--check` normalizes ISO
// dates out before comparing, so a correctly-scrubbed file for a different day
// still matches; the structural content and the version are what the check
// actually gates on.
const normalizeDates = (content: string): string =>
  content.replaceAll(/\d{4}-\d{2}-\d{2}/g, 'YYYY-MM-DD');

type CheckArgs = {
  date: string;
  hotPath: string;
  logPath: string;
  version: string;
};

// `--check`: compare the committed wiki/hot.md and wiki/log.md against
// freshly-rendered release-clean output and exit non-zero on drift, writing
// nothing. Guards a release from shipping a stale (unrendered) wiki because
// `release scrub-wiki` was skipped before the tag.
const runCheck = (args: CheckArgs): number => {
  const {date, hotPath, logPath, version} = args;
  const targets = [
    {label: 'wiki/hot.md', path: hotPath, rendered: renderHotMd(version, date)},
    {label: 'wiki/log.md', path: logPath, rendered: renderLogMd(version, date)},
  ];
  const drifted: string[] = [];

  try {
    for (const target of targets) {
      const missing = !existsSync(target.path);
      const stale =
        !missing &&
        normalizeDates(readFileSync(target.path, 'utf8')) !==
          normalizeDates(target.rendered);

      if (missing || stale) {
        drifted.push(target.label);
      }
    }
  } catch (error) {
    structuredError({
      code: 'scrub_check_read_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub-wiki',
    });

    return UNEXPECTED_EXIT;
  }

  if (drifted.length > 0) {
    structuredError({
      code: 'scrub_check_drift',
      message: `stale wiki file(s); release scrub-wiki was not run before the release: ${drifted.join(', ')}`,
      subcommand: 'release scrub-wiki',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return EXIT_CODES.OK;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
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

  if (parsed.flags.check) {
    return runCheck({date, hotPath, logPath, version});
  }

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
