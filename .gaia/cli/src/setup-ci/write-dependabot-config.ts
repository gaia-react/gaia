/**
 * `gaia setup-ci write-dependabot-config [--json]` handler.
 *
 * Renders the `/setup-gaia` Dependabot security-updates opt-in
 * (`.github/dependabot.yml`): a grouped, security-updates-only `npm`
 * entry with `open-pull-requests-limit: 0` so `/update-deps` keeps owning
 * routine version updates. When a dependabot config already exists, this
 * text-merges the entry in rather than re-dumping the parsed YAML, which
 * would destroy the adopter's comments and formatting; every merge path
 * re-parses the result and verifies the pre-existing entries came through
 * unchanged before writing.
 *
 * Output JSON, always exactly one line on stdout:
 *   `{"status":"created","path":...}`: no file existed, wrote fresh.
 *   `{"status":"merged","path":...}`: text-merged the npm entry in.
 *   `{"status":"npm_entry_exists","path":...}`: already has an npm
 *     entry; wrote nothing.
 *   `{"status":"unmergeable","path":...,"reason":...,"entry":...}`:
 *     wrote nothing; `entry` is the rendered block for manual paste.
 *     `reason` is one of: malformed, updates_not_last, verify_failed.
 */
import {load as parseYaml} from 'js-yaml';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const HELP_TEXT = `Usage: gaia setup-ci write-dependabot-config [--json]

  Render or merge the npm security-updates entry into
  .github/dependabot.yml. Always prints one JSON status line.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const NPM_ENTRY_LINES = [
  '- package-ecosystem: "npm"',
  '  directory: "/"',
  '  schedule:',
  '    interval: "weekly"',
  '  open-pull-requests-limit: 0',
  '  groups:',
  '    npm-security:',
  '      applies-to: security-updates',
  '      patterns:',
  '        - "*"',
  '  labels:',
  '    - "dependencies"',
  '    - "security"',
  '  commit-message:',
  '    prefix: "fix"',
  '    include: "scope"',
] as const;

const FRESH_FILE_HEADER = `# Rendered by /setup-gaia (Dependabot security updates opt-in).
# open-pull-requests-limit: 0 disables version updates, so /update-deps owns
# routine upgrades; security-update pull requests are not subject to that
# limit. The group collapses each batch of security fixes into one pull
# request. cooldown does not apply to security updates; pnpm's
# minimumReleaseAge still does, so a fix younger than the window fails the
# pull request's install until it ages out or is excluded by hand. The
# "fix" prefix is deliberate: a chore(deps) title would trip the dep-bump
# bypass and skip the test suite and the audit.
`;

const indentLines = (lines: readonly string[], indent: string): string[] =>
  lines.map((line) => `${indent}${line}`);

const renderFreshFile = (): string =>
  `${FRESH_FILE_HEADER}version: 2\nupdates:\n${indentLines(NPM_ENTRY_LINES, '  ').join('\n')}\n`;

const UPDATES_LINE_RE = /^updates:\s*(#.*)?$/;
const ITEM_LINE_RE = /^(\s*)- /;

/**
 * Walks the lines after `updates:` and returns the indent of its first
 * item (`- package-ecosystem: ...`), or `false` when a line in that
 * region starts a new top-level key rather than continuing the block.
 * Blank lines, comments, and item-body continuation lines are ignored.
 */
type ItemIndentResult = {indent: string; ok: true} | {ok: false};

type MergeResult =
  | {reason: 'updates_not_last' | 'verify_failed'; status: 'unmergeable'}
  | {status: 'merged'; text: string};

const findItemIndent = (
  lines: readonly string[],
  updatesLineIndex: number
): ItemIndentResult => {
  let itemIndent: string | undefined;

  for (const line of lines.slice(updatesLineIndex + 1)) {
    const trimmed = line.trim();

    if (trimmed !== '' && !trimmed.startsWith('#')) {
      const itemMatch = ITEM_LINE_RE.exec(line);

      if (itemMatch) {
        const [, capturedIndent] = itemMatch;
        itemIndent ??= capturedIndent;
      } else if (!/^\s/.test(line)) {
        return {ok: false};
      }
    }
  }

  return {indent: itemIndent ?? '  ', ok: true};
};

/**
 * Re-parses the merged text and confirms the pre-existing `updates`
 * entries came through unchanged and the appended entry has the shape
 * the caller relies on, before the caller writes anything to disk.
 */
const verifyMergedUpdates = (
  mergedText: string,
  originalUpdates: readonly unknown[]
): boolean => {
  let reparsed: unknown;

  try {
    reparsed = parseYaml(mergedText);
  } catch {
    return false;
  }

  if (typeof reparsed !== 'object' || reparsed === null) return false;
  if (Array.isArray(reparsed)) return false;

  const mergedUpdatesRaw = (reparsed as Record<string, unknown>).updates;

  if (!Array.isArray(mergedUpdatesRaw)) return false;

  const mergedUpdates: unknown[] = mergedUpdatesRaw;

  if (mergedUpdates.length !== originalUpdates.length + 1) return false;

  const priorEntriesUnchanged = originalUpdates.every(
    (original, index) =>
      JSON.stringify(mergedUpdates[index]) === JSON.stringify(original)
  );

  if (!priorEntriesUnchanged) return false;

  const lastEntry: unknown = mergedUpdates.at(-1);

  if (typeof lastEntry !== 'object' || lastEntry === null) return false;

  const lastEntryRecord = lastEntry as Record<string, unknown>;

  return (
    lastEntryRecord['package-ecosystem'] === 'npm' &&
    lastEntryRecord['open-pull-requests-limit'] === 0
  );
};

/**
 * Appends `NPM_ENTRY_LINES` under the existing `updates:` block by
 * editing the raw text, never by re-dumping parsed YAML (that would
 * destroy the adopter's comments). `originalUpdates` is the already
 * -parsed `updates` array, used only to verify the merge afterward.
 */
const mergeEntry = (
  text: string,
  originalUpdates: readonly unknown[]
): MergeResult => {
  const lines = text.split('\n');
  const updatesLineIndex = lines.findIndex((line) =>
    UPDATES_LINE_RE.test(line)
  );

  if (updatesLineIndex === -1) {
    return {reason: 'updates_not_last', status: 'unmergeable'};
  }

  const itemIndentResult = findItemIndent(lines, updatesLineIndex);

  if (!itemIndentResult.ok) {
    return {reason: 'updates_not_last', status: 'unmergeable'};
  }

  const appended = indentLines(NPM_ENTRY_LINES, itemIndentResult.indent).join(
    '\n'
  );
  const base = text.endsWith('\n') ? text : `${text}\n`;
  const merged = `${base}${appended}\n`;

  if (!verifyMergedUpdates(merged, originalUpdates)) {
    return {reason: 'verify_failed', status: 'unmergeable'};
  }

  return {status: 'merged', text: merged};
};

const parseArgs = (argv: readonly string[]): 'help' | 'invalid' | 'ok' => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) return 'help';
    if (token !== '--json') return 'invalid';
  }

  return 'ok';
};

const writeUnmergeable = (
  publishedPath: string,
  reason: 'malformed' | 'updates_not_last' | 'verify_failed',
  entryText: string
): number => {
  process.stdout.write(
    `${JSON.stringify({entry: entryText, path: publishedPath, reason, status: 'unmergeable'})}\n`
  );

  return EXIT_CODES.CONFIG_INVALID;
};

type ExistingUpdates = {ok: false} | {ok: true; updates: unknown[]};

/** Parses an existing dependabot config and extracts its `updates` array. */
const parseExistingUpdates = (text: string): ExistingUpdates => {
  let parsed: unknown;

  try {
    parsed = parseYaml(text);
  } catch {
    return {ok: false};
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return {ok: false};
  }

  const {updates} = parsed as Record<string, unknown>;

  if (!Array.isArray(updates)) return {ok: false};

  return {ok: true, updates};
};

const hasNpmEntry = (updates: readonly unknown[]): boolean =>
  updates.some(
    (item) =>
      typeof item === 'object' &&
      item !== null &&
      (item as Record<string, unknown>)['package-ecosystem'] === 'npm'
  );

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const argsStatus = parseArgs(argv);

  if (argsStatus === 'help') {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (argsStatus === 'invalid') {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${argv.find((token) => token !== '--json' && !HELP_TOKENS.has(token))}`,
      subcommand: 'setup-ci write-dependabot-config',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup-ci write-dependabot-config must run inside a git repository',
      subcommand: 'setup-ci write-dependabot-config',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const ymlPath = path.join(repoRoot, '.github', 'dependabot.yml');
  const yamlPath = path.join(repoRoot, '.github', 'dependabot.yaml');
  const ymlExists = existsSync(ymlPath);
  const yamlExists = existsSync(yamlPath);

  const targetPath = ymlExists || !yamlExists ? ymlPath : yamlPath;
  const publishedPath = path.relative(repoRoot, targetPath);
  const entryText = NPM_ENTRY_LINES.join('\n');

  if (!ymlExists && !yamlExists) {
    mkdirSync(path.dirname(targetPath), {recursive: true});
    writeFileSync(targetPath, renderFreshFile(), 'utf8');
    process.stdout.write(
      `${JSON.stringify({path: publishedPath, status: 'created'})}\n`
    );

    return EXIT_CODES.OK;
  }

  const existingText = readFileSync(targetPath, 'utf8');
  const existingUpdates = parseExistingUpdates(existingText);

  if (!existingUpdates.ok) {
    return writeUnmergeable(publishedPath, 'malformed', entryText);
  }

  const {updates} = existingUpdates;

  if (hasNpmEntry(updates)) {
    process.stdout.write(
      `${JSON.stringify({path: publishedPath, status: 'npm_entry_exists'})}\n`
    );

    return EXIT_CODES.OK;
  }

  const mergeResult = mergeEntry(existingText, updates);

  if (mergeResult.status === 'unmergeable') {
    return writeUnmergeable(publishedPath, mergeResult.reason, entryText);
  }

  writeFileSync(targetPath, mergeResult.text, 'utf8');
  process.stdout.write(
    `${JSON.stringify({path: publishedPath, status: 'merged'})}\n`
  );

  return EXIT_CODES.OK;
};
