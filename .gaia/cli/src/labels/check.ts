/**
 * `gaia labels check [--repo-root <path>] [--json]`, the code-parity check.
 *
 * Extracts every GitHub label literal in the tracked tree and fails when one
 * is absent from `.gaia/labels.json` or marked `blocked` there.
 *
 * # Why this is a CLI command and not a vitest assertion
 *
 * `run` reads the live tree. A vitest assertion over the live tree would red
 * the quality gate of every phase that has landed the registry but not yet
 * migrated the label literals the registry retires, which is a state the work
 * passes through on purpose. `check.test.ts` therefore exercises
 * `extractLiterals` against fixture strings only, and CI runs this command.
 *
 * # Why the grammar is not a `--label` scan
 *
 * A bare flag scan harvests English words out of test names, help text, and
 * error strings: `is`, `AND`, `and`, `requires`, `a`, `arms`, `exits`,
 * `re-applying`, and `failed` are all well-formed tokens the tree produces
 * today. Three constraints together remove them. A flag form counts only
 * inside a segment that begins with a `gh` invocation carrying an `issue`,
 * `pr`, or `label` verb; the `gh` must START that segment rather than appear
 * mid-string, which is what excludes an `echo` whose message quotes a `gh`
 * command; and a comment line is skipped entirely.
 *
 * The `run-audit` default lives in `.gaia/scripts/read-audit-ci-config.sh`,
 * not in `.gaia/audit-ci.yml`. That YAML file's only label-shaped key is
 * `gate_label`, which stays adopter-configurable and unowned by the registry,
 * and the extractor never reaches it.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {runGit} from '../ci/util/run-process.js';
import {EXIT_CODES} from '../exit.js';
import type {LabelRegistry} from '../schemas/labels.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {readRegistry} from './registry.js';

const HELP_TEXT = `Usage: gaia labels check [--repo-root <path>] [--json]

  Extracts every GitHub label literal in the tracked tree and fails when one
  is absent from .gaia/labels.json or marked blocked there.

  Exit 0 clean, 1 on a finding (one per line: <path>:<line>: <label>: <why>),
  2 on a usage or environment error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const EXIT_FINDING = 1;
const EXIT_ENVIRONMENT = 2;

export type LabelLiteral = {file: string; line: number; name: string};

/** Files the scan reads: `git ls-files` output minus these paths. */
export const SCAN_EXCLUDED: readonly string[] = [
  // Append-only historical record; its old entries name labels that no longer
  // exist, and correctly so.
  'CHANGELOG.md',
  // Gitignored working state.
  '.gaia/local/',
  // The wiki's own historical and audit surfaces, already exempt from the
  // sibling prose audits.
  'wiki/log.md',
  'wiki/hot.md',
  'wiki/meta/',
  // Generated bundles whose literals are the source files' literals, already
  // scanned.
  '.gaia/cli/gaia',
  '.gaia/cli/gaia-maintainer',
];

const ISSUE_TEMPLATE_DIRECTORY = '.github/ISSUE_TEMPLATE/';
const WORKFLOW_VARS_FILE = '.gaia/cli/src/automation/workflow-vars.ts';
const AUDIT_CONFIG_READER = '.gaia/scripts/read-audit-ci-config.sh';

/** A candidate that is not a placeholder or a shell expansion. */
const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9:._-]*$/u;

const COMMENT_LINE_PATTERN = /^\s*(?:#|\/\/|\*|>)/u;

/** A segment opener: line start, a pipe, `&&`, `;`, `(`, `$(`, or a backtick. */
const SEGMENT_OPENER_PATTERN = /\|{1,2}|&&|;|\$\(|\(|`/gu;

const GH_SEGMENT_PATTERN = /^\s*gh\s+(?:issue|pr|label)(?![\w-])/u;

/**
 * The unquoted alternative stops at a shell metacharacter rather than at
 * whitespace: `--label needs-human)` inside a `$(...)` would otherwise carry
 * the closing paren into the candidate, fail the token rule, and drop a real
 * literal silently.
 */
const LABEL_FLAG_PATTERN =
  /--(?:add-|remove-)?labels?(?![\w-])[\s=]+("[^"]*"|'[^']*'|[^\s"'`;|&()]+)/gu;

const LABEL_POSITIONAL_PATTERN =
  /^\s*gh\s+label\s+(?:create|edit|delete)\s+("[^"]*"|'[^']*'|[^\s"'`;|&()]+)/u;

const TEMPLATE_LABELS_PATTERN = /^labels:\s*\[([^\]]*)\]/u;

const TS_LABEL_PROPERTY_PATTERN = /\b\w*_label\s*:\s*(?:'([^']*)'|"([^"]*)")/u;

const OVERRIDE_LABEL_PATTERN = /^DEFAULT_OVERRIDE_LABEL="([^"]*)"/u;

const unquote = (value: string): string =>
  (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) ?
    value.slice(1, -1)
  : value;

/** Splits a candidate cell on commas and keeps only well-formed tokens. */
const tokensOf = (raw: string): string[] =>
  unquote(raw.trim())
    .split(',')
    .map((part) => part.trim())
    .filter((part) => TOKEN_PATTERN.test(part));

type LogicalLine = {line: number; text: string};

/**
 * Physical lines joined across backslash continuations, each carrying the
 * 1-based line the joined run STARTS on. Reporting the start rather than the
 * physical line of the flag keeps a multi-line `gh issue create` naming the
 * invocation instead of one of its argument lines.
 */
const logicalLines = (text: string): LogicalLine[] => {
  const physical = text.split('\n');
  const joined: LogicalLine[] = [];
  let index = 0;

  while (index < physical.length) {
    const start = index;
    let current = physical[index] ?? '';

    while (current.endsWith('\\') && index + 1 < physical.length) {
      index += 1;
      current = `${current.slice(0, -1)} ${physical[index] ?? ''}`;
    }

    joined.push({line: start + 1, text: current});
    index += 1;
  }

  return joined;
};

/**
 * The `gh`-rooted segments of one logical line.
 *
 * A segment runs to the end of the line rather than to the next opener,
 * because an opener also occurs inside an argument: `--title "GAIA CI: revert
 * of PR #12 also failed; bot stopped"` carries a `;` and `--body "... (GAIA CI
 * - Update Deps) ..."` carries a `(`. Cutting there drops every `--label` that
 * follows, which is precisely the multi-line `gh issue create` this scan
 * exists to read. Quote tracking would be the alternative, and it fails worse
 * on this corpus: an apostrophe in ordinary Markdown prose opens a quote that
 * never closes and swallows the rest of the line.
 *
 * The accepted miss is the mirror image, a non-`gh` command carrying a
 * label-shaped flag AFTER a `gh` command on the same line. Failing that way
 * over-reports, so the finding names a real string in the tree and a human can
 * dismiss it, rather than the check going quiet.
 */
const ghSegments = (text: string): string[] => {
  const starts = [0];

  SEGMENT_OPENER_PATTERN.lastIndex = 0;

  let match = SEGMENT_OPENER_PATTERN.exec(text);

  while (match !== null) {
    starts.push(match.index + match[0].length);
    match = SEGMENT_OPENER_PATTERN.exec(text);
  }

  return starts
    .map((start) => text.slice(start))
    .filter((segment) => GH_SEGMENT_PATTERN.test(segment));
};

const literalsInGhSegment = (segment: string): string[] => {
  const names: string[] = [];
  const positional = LABEL_POSITIONAL_PATTERN.exec(segment);

  if (positional?.[1] !== undefined) names.push(...tokensOf(positional[1]));

  LABEL_FLAG_PATTERN.lastIndex = 0;

  let match = LABEL_FLAG_PATTERN.exec(segment);

  while (match !== null) {
    if (match[1] !== undefined) names.push(...tokensOf(match[1]));
    match = LABEL_FLAG_PATTERN.exec(segment);
  }

  return names;
};

/**
 * Forms that sit outside a `gh` invocation, each pinned to the one site that
 * produces it. Pinning is what keeps `labels:` in arbitrary YAML and a
 * `*_label` property in arbitrary TypeScript out of the finding set.
 */
const pinnedLiteral = (filePath: string, text: string): string[] => {
  if (filePath.includes(ISSUE_TEMPLATE_DIRECTORY)) {
    const match = TEMPLATE_LABELS_PATTERN.exec(text);

    if (match?.[1] !== undefined) return tokensOf(match[1]);
  }

  if (filePath.endsWith(WORKFLOW_VARS_FILE)) {
    const match = TS_LABEL_PROPERTY_PATTERN.exec(text);
    const value = match?.[1] ?? match?.[2];

    if (value !== undefined) return tokensOf(value);
  }

  if (filePath.endsWith(AUDIT_CONFIG_READER)) {
    const match = OVERRIDE_LABEL_PATTERN.exec(text);

    if (match?.[1] !== undefined) return tokensOf(match[1]);
  }

  return [];
};

/** Pure. Extracts label literals from one file's text. */
export const extractLiterals = (
  filePath: string,
  text: string
): readonly LabelLiteral[] => {
  const found: LabelLiteral[] = [];
  const seen = new Set<string>();

  const record = (line: number, name: string): void => {
    const key = `${line}:${name}`;

    if (seen.has(key)) return;
    seen.add(key);
    found.push({file: filePath, line, name});
  };

  for (const {line, text: joined} of logicalLines(text)) {
    if (!COMMENT_LINE_PATTERN.test(joined)) {
      for (const segment of ghSegments(joined)) {
        for (const name of literalsInGhSegment(segment)) record(line, name);
      }

      for (const name of pinnedLiteral(filePath, joined)) record(line, name);
    }
  }

  return found;
};

/** Why a literal fails the registry check, or `null` when it resolves. */
export const literalProblem = (
  registry: LabelRegistry,
  name: string
): null | string => {
  const entry = registry.labels.find((candidate) => candidate.name === name);

  if (entry === undefined) return 'absent from .gaia/labels.json';

  return entry.blocked ?
      `blocked in .gaia/labels.json: ${entry.reason ?? ''}`
    : null;
};

const isExcluded = (file: string): boolean =>
  SCAN_EXCLUDED.some((entry) =>
    entry.endsWith('/') ? file.startsWith(entry) : file === entry
  );

type ParsedArgs = {json: boolean; repoRoot: string | undefined};

const parseArgs = (argv: readonly string[]): ParsedArgs | {code: number} => {
  let json = false;
  let repoRoot: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? '';

    if (token === '--json') {
      json = true;
    } else if (token === '--repo-root') {
      const taken = takeNonFlagValue(argv, index + 1, '--repo-root');

      if (!taken.ok) {
        structuredError({
          code: 'invalid_arguments',
          message: taken.message,
          subcommand: 'labels check',
        });

        return {code: EXIT_ENVIRONMENT};
      }
      repoRoot = taken.value;
      index += 1;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown argument: ${token}`,
        subcommand: 'labels check',
      });

      return {code: EXIT_ENVIRONMENT};
    }
  }

  return {json, repoRoot};
};

type Finding = LabelLiteral & {why: string};

const NUL = String.fromCodePoint(0);

/**
 * One tracked file's text, or null when it is unreadable or binary. A NUL byte
 * is how a blob decoded as UTF-8 announces itself, and no label literal lives
 * in one.
 */
const readScannableFile = (absolutePath: string): null | string => {
  try {
    const text = readFileSync(absolutePath, 'utf8');

    return text.includes(NUL) ? null : text;
  } catch {
    return null;
  }
};

const scanTree = (
  repoRoot: string,
  registry: LabelRegistry,
  files: readonly string[]
): Finding[] => {
  const findings: Finding[] = [];

  for (const file of files) {
    const text = readScannableFile(path.join(repoRoot, file));

    if (text !== null) {
      for (const literal of extractLiterals(file, text)) {
        const why = literalProblem(registry, literal.name);

        if (why !== null) findings.push({...literal, why});
      }
    }
  }

  return findings;
};

export const run = (argv: readonly string[]): number => {
  const first = argv[0];

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('code' in parsed) return parsed.code;

  let registry: LabelRegistry;
  let repoRoot: string;

  try {
    repoRoot = parsed.repoRoot ?? resolveRepoRoot();
    registry = readRegistry(repoRoot);
  } catch (error) {
    structuredError({
      code: 'labels_check_environment',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'labels check',
    });

    return EXIT_ENVIRONMENT;
  }

  const listed = runGit(['ls-files'], {cwd: repoRoot});

  if (listed.exitCode !== 0) {
    structuredError({
      code: 'git_invocation_failed',
      exit_code: listed.exitCode,
      message: listed.stderr.trim() || `git ls-files exited ${listed.exitCode}`,
      subcommand: 'labels check',
    });

    return EXIT_ENVIRONMENT;
  }

  const files = listed.stdout
    .split('\n')
    .filter((file) => file !== '' && !isExcluded(file));

  const findings = scanTree(repoRoot, registry, files);

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify({findings})}\n`);
  } else {
    for (const finding of findings) {
      process.stdout.write(
        `${finding.file}:${finding.line}: ${finding.name}: ${finding.why}\n`
      );
    }
  }

  return findings.length === 0 ? EXIT_CODES.OK : EXIT_FINDING;
};
