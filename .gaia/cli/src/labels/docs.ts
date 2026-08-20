/**
 * `gaia labels docs [--repo-root <path>] [--check]`
 *
 * Rewrites the generated span of `wiki/concepts/GitHub Labels.md` from
 * `.gaia/labels.json`. `renderGeneratedSpan` and `spliceGeneratedSpan` are
 * pure, and the module reaches no network and no `gh`: it imports the shared
 * process runner nowhere, which its own suite pins. `run` shells out exactly
 * once, to `resolveRepoRoot` for the default tree root, which `--repo-root`
 * replaces.
 *
 * Two properties the page's consumers depend on:
 *
 * Everything above the start marker and below the end marker is hand-authored
 * and the generator never touches a byte of it, which is what makes the
 * "Project labels" appendix safe to edit and `--check` deterministic.
 *
 * The `## GAIA labels` tables carry no maintainer-audience row, and the
 * maintainer-only material sits in one marker-wrapped section of its own.
 * `.gaia/release-scrub.yml` marker-strips `wiki/**` and drops the same entries
 * from the shipped registry, so a maintainer row left inside an adopter table
 * would red an adopter's own `gaia labels docs --check` on a page they never
 * edited. The blank lines bracketing the maintainer block sit INSIDE the
 * marker pair for the same reason: the strip must leave exactly the bytes a
 * maintainer-free registry renders.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import type {LabelAxis, LabelEntry, LabelRegistry} from '../schemas/labels.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {readRegistry} from './registry.js';

const HELP_TEXT = `Usage: gaia labels docs [--repo-root <path>] [--check]

  Rewrites the generated span of wiki/concepts/GitHub Labels.md from
  .gaia/labels.json. Deterministic and offline.

  --check   Do not write. Exit 0 when the committed span already equals a
            fresh generation, 1 when it differs (printing a unified diff),
            2 on a usage or environment error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/** Non-zero exits `gaia labels docs` contracts with its CI caller. */
const EXIT_DIFFERS = 1;
const EXIT_ENVIRONMENT = 2;

/** The two literal marker lines delimiting the generated span. */
export const GENERATED_START_MARKER = '<!-- gaia:labels:generated-start -->';

export const GENERATED_END_MARKER = '<!-- gaia:labels:generated-end -->';

/**
 * The edge is interpolated rather than spelled into two whole literals, so the
 * full marker never appears in the shipped adopter bundle: esbuild copies a
 * string constant in verbatim and does not inline this call. Writing it as a
 * literal reds the release, because `02-leak-replay.sh` and `03-marker-strip.sh`
 * scan the whole staged tree for the full spelling and have no allowlist. Every
 * other shipped file naming the marker survives by sitting inside a marker block
 * the scrub removes, which a compiled bundle cannot carry. That harness is the
 * backstop against a revert to a literal; `docs.test.ts` pins only the spelling,
 * which a literal would satisfy too.
 *
 * This cannot move to a maintainer-only module instead: the span emits the
 * marker block on a runtime registry condition, not a compile-time one, so
 * esbuild has nothing to tree-shake, and the adopter needs the same renderer for
 * `docs --check` anyway.
 */
const maintainerMarker = (edge: 'end' | 'start'): string =>
  `<!-- gaia:maintainer-only:${edge} -->`;

const MAINTAINER_START_MARKER = maintainerMarker('start');
const MAINTAINER_END_MARKER = maintainerMarker('end');

const PALETTE_RULE =
  'Warm families (red, orange, amber) are reserved for attention: urgency, defect type, and the gates that require a human. Every purely classificatory axis takes a cool or neutral family instead, high-frequency structural labels stay near grey so they recede, no two entries share a hex value, and every hex value is lowercase.';

const MAINTAINER_INTRO =
  'These labels serve the GAIA maintainer repository. Sync never creates them on an adopter repository, and the bundle-time scrub removes this section from the page an adopter receives.';

const TABLE_HEADER = '| Label | Color | Description | Created by |';
const TABLE_SEPARATOR = '| --- | --- | --- | --- |';

const AXIS_TITLES: Readonly<Record<LabelAxis, string>> = {
  attention: 'Attention gate',
  audience: 'Audience',
  blocked: 'Blocked',
  disposition: 'Disposition',
  effort: 'Effort',
  lifecycle: 'Lifecycle',
  modifier: 'Modifier',
  origin: 'Origin and trigger',
  reach: 'Reach of fix',
  'third-party': 'Third-party',
  type: 'Type',
  urgency: 'Urgency',
};

const createdBy = (entry: LabelEntry): string => {
  if (!entry.managed) return 'documented only';

  return entry.features.length === 0 ? 'always' : entry.features.join(', ');
};

const entryRow = (entry: LabelEntry): string =>
  `| \`${entry.name}\` | \`${entry.color ?? 'none'}\` | ${entry.description} | ${createdBy(entry)} |`;

/** Distinct axes in the order the registry's own array first reaches them. */
const axisOrder = (entries: readonly LabelEntry[]): readonly LabelAxis[] => {
  const seen: LabelAxis[] = [];

  for (const entry of entries) {
    if (!seen.includes(entry.axis)) seen.push(entry.axis);
  }

  return seen;
};

/** One `###` subsection per axis present in `entries`, each ending blank. */
const axisSections = (entries: readonly LabelEntry[]): string[] =>
  axisOrder(entries).flatMap((axis) => [
    `### ${AXIS_TITLES[axis]}`,
    '',
    TABLE_HEADER,
    TABLE_SEPARATOR,
    ...entries.filter((entry) => entry.axis === axis).map(entryRow),
    '',
  ]);

/** The generated body, exclusive of the markers themselves. */
export const renderGeneratedSpan = (registry: LabelRegistry): string => {
  const documented = registry.labels.filter((entry) => !entry.blocked);
  const adopter = documented.filter((entry) => entry.audience === 'adopter');
  const maintainer = documented.filter(
    (entry) => entry.audience === 'maintainer'
  );

  const lines: string[] = [
    '',
    '## GAIA labels',
    '',
    ...axisSections(adopter),
    '## Palette rule',
    '',
    PALETTE_RULE,
    '',
  ];

  if (maintainer.length > 0) {
    lines.push(
      MAINTAINER_START_MARKER,
      '',
      '## Maintainer-only labels',
      '',
      MAINTAINER_INTRO,
      '',
      ...axisSections(maintainer),
      MAINTAINER_END_MARKER
    );
  }

  lines.push(
    '## Deliberately absent',
    '',
    '| Label | Reason |',
    '| --- | --- |',
    ...registry.labels
      .filter((entry) => entry.blocked)
      .map((entry) => `| \`${entry.name}\` | ${entry.reason ?? ''} |`),
    ''
  );

  return lines.join('\n');
};

const markerLines = (lines: readonly string[], marker: string): number[] =>
  lines.flatMap((line, index) => (line === marker ? [index] : []));

/** Splices a fresh span into the page text between the markers. */
export const spliceGeneratedSpan = (pageText: string, span: string): string => {
  const lines = pageText.split('\n');
  const starts = markerLines(lines, GENERATED_START_MARKER);
  const ends = markerLines(lines, GENERATED_END_MARKER);

  if (starts.length !== 1 || ends.length !== 1) {
    throw new Error(
      `expected exactly one ${GENERATED_START_MARKER} line and one ${GENERATED_END_MARKER} line, found ${starts.length} and ${ends.length}`
    );
  }

  const start = starts[0] ?? 0;
  const end = ends[0] ?? 0;

  if (start >= end) {
    throw new Error(
      `${GENERATED_END_MARKER} appears at line ${end + 1}, at or above its start marker at line ${start + 1}`
    );
  }

  return [
    ...lines.slice(0, start + 1),
    ...span.split('\n'),
    ...lines.slice(end),
  ].join('\n');
};

/** One hunk covering everything between the common prefix and suffix. */
const unifiedDiff = (
  label: string,
  committed: readonly string[],
  generated: readonly string[]
): string => {
  let prefix = 0;

  while (
    prefix < committed.length &&
    prefix < generated.length &&
    committed[prefix] === generated[prefix]
  ) {
    prefix += 1;
  }

  let suffix = 0;

  while (
    suffix < committed.length - prefix &&
    suffix < generated.length - prefix &&
    committed[committed.length - 1 - suffix] ===
      generated[generated.length - 1 - suffix]
  ) {
    suffix += 1;
  }

  const removed = committed.slice(prefix, committed.length - suffix);
  const added = generated.slice(prefix, generated.length - suffix);

  return [
    `--- ${label} (committed)`,
    `+++ ${label} (generated)`,
    `@@ -${prefix + 1},${removed.length} +${prefix + 1},${added.length} @@`,
    ...removed.map((line) => `-${line}`),
    ...added.map((line) => `+${line}`),
    '',
  ].join('\n');
};

type ParsedArgs = {check: boolean; repoRoot: string | undefined};

const parseArgs = (argv: readonly string[]): ParsedArgs | {code: number} => {
  let check = false;
  let repoRoot: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--check') {
      check = true;
    } else if (token === '--repo-root') {
      const value = takeNonFlagValue(argv, index + 1, '--repo-root');

      if (!value.ok) {
        structuredError({
          code: 'invalid_arguments',
          message: value.message,
          subcommand: 'labels docs',
        });

        return {code: EXIT_ENVIRONMENT};
      }
      repoRoot = value.value;
      index += 1;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown argument: ${token ?? ''}`,
        subcommand: 'labels docs',
      });

      return {code: EXIT_ENVIRONMENT};
    }
  }

  return {check, repoRoot};
};

/** The page this command owns, relative to the repository root. */
export const PAGE_RELATIVE_PATH = 'wiki/concepts/GitHub Labels.md';

export const run = (argv: readonly string[]): number => {
  const first = argv[0];

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('code' in parsed) return parsed.code;

  const repoRoot = parsed.repoRoot ?? resolveRepoRoot();
  const pagePath = path.join(repoRoot, PAGE_RELATIVE_PATH);

  let committed: string;
  let next: string;

  try {
    const registry = readRegistry(repoRoot);

    committed = readFileSync(pagePath, 'utf8');
    next = spliceGeneratedSpan(committed, renderGeneratedSpan(registry));
  } catch (error) {
    structuredError({
      code: 'labels_docs_environment',
      message: error instanceof Error ? error.message : String(error),
      page: PAGE_RELATIVE_PATH,
      subcommand: 'labels docs',
    });

    return EXIT_ENVIRONMENT;
  }

  if (!parsed.check) {
    const rewritten = next !== committed;

    if (rewritten) atomicWriteFileSync(pagePath, next);

    const outcome = rewritten ? 'rewritten' : 'already current';

    process.stdout.write(`labels-docs: ${PAGE_RELATIVE_PATH} ${outcome}\n`);

    return EXIT_CODES.OK;
  }

  if (next === committed) return EXIT_CODES.OK;

  process.stdout.write(
    unifiedDiff(PAGE_RELATIVE_PATH, committed.split('\n'), next.split('\n'))
  );

  return EXIT_DIFFERS;
};
