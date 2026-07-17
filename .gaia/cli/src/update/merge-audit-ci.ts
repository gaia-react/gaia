import {load as parseYaml} from 'js-yaml';
/**
 * `gaia update merge-audit-ci --baseline <file> --latest <file> --current <file>`
 * handler.
 *
 * Field-aware verdict oracle for `.gaia/audit-ci.yml`, the audit analog of the
 * `pnpm-workspace.yaml` step in `/update-gaia`. The file is mixed: GAIA-authored
 * scalar knobs (`gate_label`, `budget_seconds`, `max_turns`, `push_fixes`,
 * `default_mode`, `override_label`, the `retrigger_workflows` list), the
 * adopter-extensible `audit_authors` string (per-developer `login=mode` entries
 * the adopter commits), and the `auditors` roster list, GAIA-authored **and**
 * adopter-extensible at once (a member GAIA ships alongside any member an
 * adopter has added of their own). A whole-file three-way merge produces a
 * full-file conflict patch the moment an adopter adds one `audit_authors`
 * entry or one roster member, so this command merges at key / per-entry
 * granularity instead.
 *
 * It is READ-ONLY: it parses the three YAML files with js-yaml and emits a JSON
 * verdict report. It never writes the file; the `/update-gaia` skill applies
 * `applied[]` with the Edit tool so comments, key order, and quote style
 * survive.
 *
 * Verdict table (identical to the package.json / pnpm-workspace steps), per
 * managed scalar key and per `audit_authors` login, with baseline `B` /
 * latest `L` / adopter `A`:
 *
 *   in B and L, B == L                     → no-op  (adopter's value stands)
 *   in B and L, B != L, A present, A == B  → apply  (take latest)
 *   in B and L, B != L, A present, A != B  → conflict (keep adopter, note both)
 *   in B and L, B != L, A removed          → suggestion (removed-then-changed)
 *   in L, not in B                         → suggestion (added)
 *   in B, not in L                         → no-op  (adopter keeps theirs)
 *
 * The `audit_authors` value is a single space-separated `login=mode` string on
 * each side; it is parsed into per-login entries keyed case-insensitively on the
 * login (matching the resolver's case-fold), and iterated over keys(B) ∪ keys(L)
 * so an adopter-only login is never visited, never clobbered, never conflicted.
 *
 * The `auditors` roster list is keyed on member `name` exactly (not
 * case-folded: a member name is an agent filename, not a case-insensitive
 * GitHub login) and iterated the same keys(B) ∪ keys(L) way. **One row is
 * changed for this section only**: `in L, not in B` resolves to `apply`, not
 * `suggestion (added)`. See the comment at the roster-merge call site for why.
 *
 * Object-map dispatch and no-switch style per the project's typescript rules.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia update merge-audit-ci --baseline <file> --latest <file> --current <file> [--json]

  Field-aware three-way verdict for .gaia/audit-ci.yml. Reads three YAML files
  (baseline / latest tarball + working-tree current), classifies the GAIA-managed
  scalar knobs, the adopter-shared audit_authors login=mode entries, and the
  auditors roster members, and emits a JSON report of {applied, conflicts,
  suggestions}.

  Read-only: never writes the file. The /update-gaia skill applies the 'applied'
  entries with the Edit tool to preserve comments and order.

  Exit codes:
    0  success
    1  user-correctable error (missing flag / file, malformed YAML)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

/**
 * GAIA-managed top-level keys, merged whole-value (the adopter's whole value
 * for the key is compared / applied as a unit; the `retrigger_workflows` list
 * included).
 */
const MANAGED_WHOLE_VALUE_KEYS: readonly string[] = [
  'gate_label',
  'budget_seconds',
  'max_turns',
  'push_fixes',
  'default_mode',
  'override_label',
  'retrigger_workflows',
];

/** The adopter-shared section: a space-separated `login=mode` string. */
const AUTHORS_SECTION = 'audit_authors';

/** The GAIA-authored-and-adopter-extensible roster list. */
const ROSTER_SECTION = 'auditors';

export type AuditCiMergeReport = {
  applied: AuditCiVerdictItem[];
  conflicts: AuditCiVerdictItem[];
  suggestions: AuditCiVerdictItem[];
};

export type AuditCiVerdictItem = {
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

const VALUE_FLAGS: Readonly<Record<string, keyof Flags>> = {
  '--baseline': 'baseline',
  '--current': 'current',
  '--latest': 'latest',
};

// `Record<string, T>` indexing types as `T`, never `undefined`, without
// `noUncheckedIndexedAccess` — but `token` may not be one of VALUE_FLAGS'
// three known keys, and that absence is exactly what routes to the
// unknown-flag branch below.
const lookupValueFlag = (token: string): keyof Flags | undefined =>
  (VALUE_FLAGS as Record<string, keyof Flags | undefined>)[token];

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const collected: Partial<Record<keyof Flags, string>> = {};
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const field = lookupValueFlag(token);

    if (token === '--json') {
      json = true;
    } else if (field === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      collected[field] = taken.value;
      index += 1;
    }
  }

  const {baseline, current, latest} = collected;

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

/**
 * Parse a space-separated `login=mode` string into a login → mode map keyed
 * case-insensitively on the login (matching the resolver's case-fold). Each
 * entry keeps the original (display-cased) login under `display` so the verdict
 * report shows the source spelling. Malformed tokens (no `=`, empty login, or
 * empty mode) are skipped, mirroring the resolver's skip-malformed behavior.
 */
type AuthorEntry = {display: string; mode: string};

const parseAuthors = (value: unknown): Map<string, AuthorEntry> => {
  const entries = new Map<string, AuthorEntry>();

  if (typeof value !== 'string') return entries;

  for (const token of value.split(/\s+/)) {
    if (token.length > 0) {
      const eq = token.indexOf('=');

      // eq > 0 && eq < token.length - 1: has '=', with a non-empty login
      // and a non-empty mode either side of it.
      if (eq > 0 && eq !== token.length - 1) {
        const login = token.slice(0, eq);
        const mode = token.slice(eq + 1);
        const lowerLogin = login.toLowerCase();

        // First occurrence wins, matching the resolver's first-match-wins scan.
        if (!entries.has(lowerLogin))
          entries.set(lowerLogin, {display: login, mode});
      }
    }
  }

  return entries;
};

/**
 * Parse a YAML `auditors:` list into a name → member-config map. Each
 * member's whole mapping (`globs`, `scope`, `push_fixes`, `default`) is
 * compared and applied as a single unit, mirroring `parseAuthors`'s `mode`
 * value: `name` is the map key (like `login`), the rest of the item is the
 * value (like `mode`). A per-glob merge would let an adopter's roster end up
 * with a glob set neither side ever authored. Malformed entries (no `name`,
 * or a `name` that is not a string) are skipped, mirroring `parseAuthors`'s
 * skip-malformed behavior; a malformed roster must not crash the update.
 */
type RosterMember = Record<string, unknown>;

const omitName = (item: Record<string, unknown>): RosterMember => {
  const config: RosterMember = {};

  for (const key of Object.keys(item)) {
    if (key !== 'name') config[key] = item[key];
  }

  return config;
};

const parseRoster = (value: unknown): Map<string, RosterMember> => {
  const entries = new Map<string, RosterMember>();

  if (!Array.isArray(value)) return entries;

  for (const item of value) {
    const name =
      typeof item === 'object' && item !== null && !Array.isArray(item) ?
        (item as Record<string, unknown>).name
      : undefined;

    // First occurrence wins, matching parseAuthors' first-match-wins scan.
    if (typeof name === 'string' && !entries.has(name))
      entries.set(name, omitName(item as Record<string, unknown>));
  }

  return entries;
};

type Verdict =
  'apply' | 'conflict' | 'noop' | 'suggest-add' | 'suggest-removed';

type VerdictInputs = {
  a: Presence;
  /**
   * The verdict for the `in L, not in B` row: every section defaults to
   * `suggest-add`, except the `auditors` roster (UAT-038, see the
   * roster-merge call site), which passes `apply`.
   */
  addedVerdict?: 'apply' | 'suggest-add';
  b: Presence;
  l: Presence;
};

const computeVerdict = ({
  a,
  addedVerdict = 'suggest-add',
  b,
  l,
}: VerdictInputs): Verdict => {
  if (b.has && l.has) {
    if (deepEqual(b.value, l.value)) return 'noop';
    if (!a.has) return 'suggest-removed';
    if (deepEqual(a.value, b.value)) return 'apply';

    return 'conflict';
  }

  if (l.has) return addedVerdict;

  return 'noop';
};

type Triple = {
  a: Presence;
  addedVerdict?: 'apply' | 'suggest-add';
  b: Presence;
  key: string;
  kind: 'entry' | 'key';
  l: Presence;
  section?: string;
};

const buildItem = (triple: Triple): AuditCiVerdictItem => {
  const item: AuditCiVerdictItem = {key: triple.key, kind: triple.kind};

  if (triple.section !== undefined) item.section = triple.section;
  if (triple.b.has) item.baseline = triple.b.value;
  if (triple.l.has) item.latest = triple.l.value;
  if (triple.a.has) item.adopter = triple.a.value;

  return item;
};

const sortKey = (item: AuditCiVerdictItem): string =>
  `${item.section ?? ''} ${item.key}`;

const bySortKey = (a: AuditCiVerdictItem, b: AuditCiVerdictItem): number =>
  sortKey(a).localeCompare(sortKey(b));

const authorPresence = (
  entries: Map<string, AuthorEntry>,
  login: string
): Presence => {
  const entry = entries.get(login);

  return entry === undefined ?
      {has: false, value: undefined}
    : {has: true, value: entry.mode};
};

const rosterPresence = (
  entries: Map<string, RosterMember>,
  name: string
): Presence => {
  const entry = entries.get(name);

  return entry === undefined ?
      {has: false, value: undefined}
    : {has: true, value: entry};
};

const computeReport = (
  baseline: Record<string, unknown>,
  latest: Record<string, unknown>,
  current: Record<string, unknown>
): AuditCiMergeReport => {
  const applied: AuditCiVerdictItem[] = [];
  const conflicts: AuditCiVerdictItem[] = [];
  const suggestions: AuditCiVerdictItem[] = [];

  const triples: Triple[] = [];

  for (const key of MANAGED_WHOLE_VALUE_KEYS) {
    triples.push({
      a: lookup(current, key),
      b: lookup(baseline, key),
      key,
      kind: 'key',
      l: lookup(latest, key),
    });
  }

  // audit_authors: parse each side's login=mode string and merge per login over
  // keys(B) ∪ keys(L) only, so an adopter-only login is never visited.
  const baseAuthors = parseAuthors(baseline[AUTHORS_SECTION]);
  const latestAuthors = parseAuthors(latest[AUTHORS_SECTION]);
  const currentAuthors = parseAuthors(current[AUTHORS_SECTION]);
  const authorLogins = [
    ...new Set([...baseAuthors.keys(), ...latestAuthors.keys()]),
  ];

  for (const login of authorLogins) {
    // The display key is the latest spelling if present, else the baseline one.
    const display =
      latestAuthors.get(login)?.display ??
      baseAuthors.get(login)?.display ??
      login;
    triples.push({
      a: authorPresence(currentAuthors, login),
      b: authorPresence(baseAuthors, login),
      key: display,
      kind: 'entry',
      l: authorPresence(latestAuthors, login),
      section: AUTHORS_SECTION,
    });
  }

  // auditors: the roster is a *third* kind of content, GAIA-authored and
  // adopter-extensible at once. It reuses the same keys(B) ∪ keys(L) shape as
  // audit_authors above, keyed on member `name` exactly, with exactly one
  // changed row: `in L, not in B` (a GAIA-authored member the adopter's file
  // has never seen) resolves to `apply`, not `suggest-add`. Every other
  // section treats that row as an opt-in suggestion, surfaced but never
  // written; a roster member is a capability the adopter cannot opt into if
  // it never arrives, unlike a scalar knob they already have a value for, so
  // leaving it a suggestion would mean a new GAIA-authored member (e.g.
  // code-audit-github-workflows) reaches no existing adopter. This is a
  // named, deliberate divergence from every other section's added-row
  // semantics (UAT-038), not an inconsistency to "fix". Bounded precisely: an
  // adopter's *edit* to a GAIA-authored member is still a conflict below, and
  // an adopter's *own* member (present only in current) is never visited.
  const baseRoster = parseRoster(baseline[ROSTER_SECTION]);
  const latestRoster = parseRoster(latest[ROSTER_SECTION]);
  const currentRoster = parseRoster(current[ROSTER_SECTION]);
  const rosterNames = [
    ...new Set([...baseRoster.keys(), ...latestRoster.keys()]),
  ];

  for (const name of rosterNames) {
    triples.push({
      a: rosterPresence(currentRoster, name),
      addedVerdict: 'apply',
      b: rosterPresence(baseRoster, name),
      key: name,
      kind: 'entry',
      l: rosterPresence(latestRoster, name),
      section: ROSTER_SECTION,
    });
  }

  for (const triple of triples) {
    const verdict = computeVerdict({
      a: triple.a,
      addedVerdict: triple.addedVerdict,
      b: triple.b,
      l: triple.l,
    });

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

  return {
    applied: applied.toSorted(bySortKey),
    conflicts: conflicts.toSorted(bySortKey),
    suggestions: suggestions.toSorted(bySortKey),
  };
};

const printHuman = (report: AuditCiMergeReport): void => {
  const lines = [
    'gaia update merge-audit-ci',
    `  Applied:     ${report.applied.length}`,
    `  Conflicts:   ${report.conflicts.length}`,
    `  Suggestions: ${report.suggestions.length}`,
  ];

  const label = (item: AuditCiVerdictItem): string =>
    item.section === undefined ? item.key : `${item.section}.${item.key}`;

  const sections: [string, readonly AuditCiVerdictItem[]][] = [
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
      code: 'audit_ci_file_missing' | 'audit_ci_parse_failed';
      message: string;
      ok: false;
    }
  | {ok: true; root: Record<string, unknown>};

const loadAuditCi = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'audit_ci_file_missing',
      message: `${role} audit-ci file not found: ${absPath}`,
      ok: false,
    };
  }

  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(absPath, 'utf8'));
  } catch (error) {
    return {
      code: 'audit_ci_parse_failed',
      message: `${role} audit-ci file is not valid YAML (${absPath}): ${
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
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update merge-audit-ci',
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
    const result = loadAuditCi(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-audit-ci',
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
