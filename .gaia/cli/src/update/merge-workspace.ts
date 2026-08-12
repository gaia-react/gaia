/**
 * `gaia update merge-workspace --baseline <file> --latest <file> --current <file>`
 * handler.
 *
 * Field-aware verdict oracle for `pnpm-workspace.yaml`, the YAML analog of
 * the `package.json` step in `/update-gaia`. The file is mixed: GAIA-authored
 * supply-chain / resolution settings plus adopter-extensible `overrides` and
 * `allowBuilds` maps. A whole-file three-way merge produces a full-file
 * conflict patch the moment an adopter adds a single override, so this command
 * merges at key / map-entry granularity instead.
 *
 * It is READ-ONLY: it parses the three YAML files with js-yaml and emits a
 * JSON verdict report. It never writes the workspace file; the `/update-gaia`
 * skill applies `applied[]` with the Edit tool so comments, key order, and
 * quote style survive (js-yaml `dump` would strip every comment).
 *
 * Verdict table (identical to the package.json step), per managed key or per
 * `overrides` / `allowBuilds` entry key, with baseline `B` / latest `L` /
 * adopter `A`:
 *
 *   in B and L, B == L                     → no-op  (adopter's value stands)
 *   in B and L, B != L, A present, A == B  → apply  (take latest)
 *   in B and L, B != L, A present, A != B  → conflict (keep adopter, note both)
 *   in B and L, B != L, A removed          → suggestion (removed-then-changed)
 *   in L, not in B                         → suggestion (added)
 *   in B, not in L                         → no-op  (adopter keeps theirs)
 *
 * Object-map dispatch and no-switch style per the project's typescript rules.
 */
import {load as parseYaml} from 'js-yaml';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseValueFlags} from '../util/parse-value-flags.js';
import type {ValueFlagMap} from '../util/parse-value-flags.js';

const HELP_TEXT = `Usage: gaia update merge-workspace --baseline <file> --latest <file> --current <file> [--json]

  Field-aware three-way verdict for pnpm-workspace.yaml. Reads three YAML
  files (baseline / latest tarball + working-tree current), classifies the
  GAIA-managed keys and the adopter-shared overrides / allowBuilds maps, and
  emits a JSON report of {applied, conflicts, suggestions}.

  Read-only: never writes the workspace file. The /update-gaia skill applies
  the 'applied' entries with the Edit tool to preserve comments and order.

  Exit codes:
    0  success
    1  user-correctable error (missing flag / file, malformed YAML)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * GAIA-managed top-level keys, merged whole-value (the adopter's whole value
 * for the key is compared / applied as a unit; lists included).
 */
const MANAGED_WHOLE_VALUE_KEYS: readonly string[] = [
  'minimumReleaseAge',
  'minimumReleaseAgeStrict',
  'trustPolicy',
  'trustPolicyExclude',
  'minimumReleaseAgeExclude',
  'publicHoistPattern',
  'savePrefix',
  'strictPeerDependencies',
];

/**
 * Adopter-shared map sections, merged per entry key. Adopter-only entries are
 * never visited (iteration is over baseline ∪ latest keys), so they are never
 * clobbered.
 */
const SHARED_MAP_SECTIONS: readonly string[] = ['overrides', 'allowBuilds'];

export type WorkspaceMergeReport = {
  applied: WorkspaceVerdictItem[];
  conflicts: WorkspaceVerdictItem[];
  suggestions: WorkspaceVerdictItem[];
};

export type WorkspaceVerdictItem = {
  adopter?: unknown;
  baseline?: unknown;
  key: string;
  kind: 'entry' | 'key';
  latest?: unknown;
  reason?: 'added' | 'removed-then-changed';
  section?: string;
};

type Flags = {
  baseline: string;
  current: string;
  json: boolean;
  latest: string;
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

const VALUE_FLAGS: ValueFlagMap<keyof Flags> = {
  '--baseline': 'baseline',
  '--current': 'current',
  '--latest': 'latest',
};

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const parsed = parseValueFlags(argv, VALUE_FLAGS);

  if (!parsed.ok) return parsed;

  const {
    collected: {baseline, current, latest},
    json,
  } = parsed.state;

  if (baseline === undefined)
    return {message: '--baseline is required', ok: false};

  if (latest === undefined) return {message: '--latest is required', ok: false};

  if (current === undefined)
    return {message: '--current is required', ok: false};

  return {flags: {baseline, current, json, latest}, ok: true};
};

const deepEqual = (a: unknown, b: unknown): boolean => {
  if (a === b) return true;
  if (a === null || b === null) return a === b;
  if (typeof a !== typeof b) return false;

  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;

    return a.every((value, index) => deepEqual(value, b[index]));
  }

  if (typeof a === 'object' && typeof b === 'object') {
    const aKeys = Object.keys(a);
    const bKeys = Object.keys(b);

    if (aKeys.length !== bKeys.length) return false;

    return aKeys.every((key) =>
      deepEqual(
        (a as Record<string, unknown>)[key],
        (b as Record<string, unknown>)[key]
      )
    );
  }

  return false;
};

type Presence = {has: boolean; value: unknown};

const lookup = (root: Record<string, unknown>, key: string): Presence =>
  Object.hasOwn(root, key) ?
    {has: true, value: root[key]}
  : {has: false, value: undefined};

const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value) ?
    (value as Record<string, unknown>)
  : {};

type Verdict =
  'apply' | 'conflict' | 'noop' | 'suggest-add' | 'suggest-removed';

const computeVerdict = (b: Presence, l: Presence, a: Presence): Verdict => {
  if (b.has && l.has) {
    if (deepEqual(b.value, l.value)) return 'noop';
    if (!a.has) return 'suggest-removed';
    if (deepEqual(a.value, b.value)) return 'apply';

    return 'conflict';
  }

  if (l.has) return 'suggest-add';

  return 'noop';
};

type Triple = {
  a: Presence;
  b: Presence;
  key: string;
  kind: 'entry' | 'key';
  l: Presence;
  section?: string;
};

const buildItem = (triple: Triple): WorkspaceVerdictItem => {
  const item: WorkspaceVerdictItem = {key: triple.key, kind: triple.kind};

  if (triple.section !== undefined) item.section = triple.section;
  if (triple.b.has) item.baseline = triple.b.value;
  if (triple.l.has) item.latest = triple.l.value;
  if (triple.a.has) item.adopter = triple.a.value;

  return item;
};

// U+0000 separates section from key because collation ignores it entirely, so
// items order by section-then-key with nothing of the separator's own weight
// competing in the comparison. It stays written as an escape: a raw NUL byte
// here lands inside git's binary-sniff window and makes the whole file read as
// binary, which drops it out of `git grep` and every plain-text diff.
const sortKey = (item: WorkspaceVerdictItem): string =>
  `${item.section ?? ''}\u0000${item.key}`;

const bySortKey = (a: WorkspaceVerdictItem, b: WorkspaceVerdictItem): number =>
  sortKey(a).localeCompare(sortKey(b));

const buildManagedKeyTriples = (
  baseline: Record<string, unknown>,
  latest: Record<string, unknown>,
  current: Record<string, unknown>
): Triple[] =>
  MANAGED_WHOLE_VALUE_KEYS.map((key) => ({
    a: lookup(current, key),
    b: lookup(baseline, key),
    key,
    kind: 'key' as const,
    l: lookup(latest, key),
  }));

type MapEntryTriplesArgs = {
  baseline: Record<string, unknown>;
  current: Record<string, unknown>;
  latest: Record<string, unknown>;
  section: string;
};

const buildMapEntryTriples = ({
  baseline,
  current,
  latest,
  section,
}: MapEntryTriplesArgs): Triple[] => {
  const baseSection = asRecord(baseline[section]);
  const latestSection = asRecord(latest[section]);
  const currentSection = asRecord(current[section]);
  const entryKeys = [
    ...new Set([...Object.keys(baseSection), ...Object.keys(latestSection)]),
  ];

  return entryKeys.map((key) => ({
    a: lookup(currentSection, key),
    b: lookup(baseSection, key),
    key,
    kind: 'entry' as const,
    l: lookup(latestSection, key),
    section,
  }));
};

type ClassifiedTriples = {
  applied: WorkspaceVerdictItem[];
  conflicts: WorkspaceVerdictItem[];
  suggestions: WorkspaceVerdictItem[];
};

const classifyTriples = (triples: readonly Triple[]): ClassifiedTriples => {
  const applied: WorkspaceVerdictItem[] = [];
  const conflicts: WorkspaceVerdictItem[] = [];
  const suggestions: WorkspaceVerdictItem[] = [];

  for (const triple of triples) {
    const verdict = computeVerdict(triple.b, triple.l, triple.a);

    if (verdict !== 'noop') {
      const item = buildItem(triple);

      if (verdict === 'apply') {
        applied.push(item);
      } else if (verdict === 'conflict') {
        conflicts.push(item);
      } else {
        item.reason =
          verdict === 'suggest-add' ? 'added' : 'removed-then-changed';
        suggestions.push(item);
      }
    }
  }

  return {applied, conflicts, suggestions};
};

const computeReport = (
  baseline: Record<string, unknown>,
  latest: Record<string, unknown>,
  current: Record<string, unknown>
): WorkspaceMergeReport => {
  const triples = [
    ...buildManagedKeyTriples(baseline, latest, current),
    ...SHARED_MAP_SECTIONS.flatMap((section) =>
      buildMapEntryTriples({baseline, current, latest, section})
    ),
  ];

  const {applied, conflicts, suggestions} = classifyTriples(triples);

  return {
    applied: applied.toSorted(bySortKey),
    conflicts: conflicts.toSorted(bySortKey),
    suggestions: suggestions.toSorted(bySortKey),
  };
};

const printHuman = (report: WorkspaceMergeReport): void => {
  const lines = [
    'gaia update merge-workspace',
    `  Applied:     ${report.applied.length}`,
    `  Conflicts:   ${report.conflicts.length}`,
    `  Suggestions: ${report.suggestions.length}`,
  ];

  const label = (item: WorkspaceVerdictItem): string =>
    item.section === undefined ? item.key : `${item.section}.${item.key}`;

  const sections: [string, readonly WorkspaceVerdictItem[]][] = [
    ['Applied', report.applied],
    ['Conflicts', report.conflicts],
    ['Suggestions', report.suggestions],
  ];

  for (const [heading, items] of sections) {
    if (items.length > 0) {
      lines.push('', `${heading}:`);

      for (const item of items) lines.push(`  ${label(item)}`);
    }
  }

  process.stdout.write(`${lines.join('\n')}\n`);
};

type LoadResult =
  | {
      code: 'workspace_file_missing' | 'workspace_parse_failed';
      message: string;
      ok: false;
    }
  | {ok: true; root: Record<string, unknown>};

const loadWorkspace = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'workspace_file_missing',
      message: `${role} workspace file not found: ${absPath}`,
      ok: false,
    };
  }

  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(absPath, 'utf8'));
  } catch (error) {
    return {
      code: 'workspace_parse_failed',
      message: `${role} workspace file is not valid YAML (${absPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      ok: false,
    };
  }

  return {ok: true, root: asRecord(parsed)};
};

type RunOptions = {
  cwd?: string;
};

const resolvePath = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update merge-workspace',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const inputs: [string, string][] = [
    ['baseline', resolvePath(cwd, parsed.flags.baseline)],
    ['latest', resolvePath(cwd, parsed.flags.latest)],
    ['current', resolvePath(cwd, parsed.flags.current)],
  ];

  const roots: Record<string, unknown>[] = [];

  for (const [role, absPath] of inputs) {
    const result = loadWorkspace(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-workspace',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    roots.push(result.root);
  }

  const [baseline, latest, current] = roots as [
    Record<string, unknown>,
    Record<string, unknown>,
    Record<string, unknown>,
  ];
  const report = computeReport(baseline, latest, current);

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    printHuman(report);
  }

  return EXIT_CODES.OK;
};
