/**
 * The `pnpm-member-strip` release-scrub transform: removes one workspace
 * member from a staged root `pnpm-workspace.yaml` and `pnpm-lock.yaml` pair,
 * so the shipped pair installs under `pnpm install --frozen-lockfile` on a
 * tree that does not carry that member. pnpm refuses a frozen install whose
 * lockfile names an importer the tree lacks, and `--filter` cannot route
 * around it because the importer check runs before filtering.
 *
 * Hermetic by design: no pnpm call and no network, because regenerating the
 * lockfile with pnpm re-verifies supply-chain policy against registry
 * metadata, which a cold release runner does not have offline.
 *
 * The lockfile is two YAML documents (pnpm's own packageManagerDependencies,
 * then the dependency document). js-yaml's `load` throws on multi-document
 * input and a load/dump round trip rewrites quoting and wrapping, so the
 * documents are split on their `---` lines, parsed only for analysis, and the
 * dependency document is edited by removing whole entry line ranges. Every
 * byte outside the removed ranges passes through unchanged.
 *
 * Pruning rule: drop a snapshot only when it is reachable from the removed
 * importer AND from no remaining importer. "Drop everything unreachable" is
 * wrong: pnpm keeps orphan snapshots in a lockfile it writes, and deleting
 * one breaks byte identity with what pnpm itself would write.
 */
import {FAILSAFE_SCHEMA, load} from 'js-yaml';

export type PnpmMemberStripInput = {
  lockfile: string;
  member: string;
  workspace: string;
};

export type PnpmMemberStripOutcome =
  | {
      detail: string;
      file: 'lockfile' | 'workspace';
      kind: 'refused';
      token: PnpmStripRefusal;
    }
  | {kind: 'noop'}
  | {
      kind: 'stripped';
      lockfile: string;
      removed: {importers: string[]; packages: string[]; snapshots: string[]};
      workspace: string;
    };

export type PnpmStripRefusal =
  | 'cli-only-key-survives'
  | 'importer-without-member'
  | 'integrity'
  | 'member-without-importer'
  | 'missing-snapshot'
  | 'unknown-lockfile-version'
  | 'unparseable';

/** Chooses which snapshot ids to drop; packages entries follow from it. */
export type PrunePolicy = (view: PruneView) => ReadonlySet<string>;

/** The reachability sets a prune policy chooses dropped snapshot ids from. */
export type PruneView = {
  memberDependencyNames: ReadonlySet<string>;
  memberReach: ReadonlySet<string>;
  restReach: ReadonlySet<string>;
  snapshotIds: readonly string[];
};

type Refused = Extract<PnpmMemberStripOutcome, {kind: 'refused'}>;

type Stripped = Extract<PnpmMemberStripOutcome, {kind: 'stripped'}>;

// The only lockfile format this line-level editor has been proven against.
// A new format fails the release loudly rather than being edited blind.
const SUPPORTED_LOCKFILE_VERSION = '9.0';
const DOCUMENT_START = '---';
const ENTRY_SECTIONS = ['importers', 'packages', 'snapshots'] as const;
const IMPORTER_DEPENDENCY_FIELDS = [
  'dependencies',
  'devDependencies',
  'optionalDependencies',
] as const;
const SNAPSHOT_DEPENDENCY_FIELDS = [
  'dependencies',
  'optionalDependencies',
] as const;
// An alias value names its real package: `name@version` or
// `@scope/name@version`. A plain version starts with a digit and is handled
// before this test.
const ALIAS_VALUE = /^(?:@[^@/]+\/)?[^@/:]+@/;
const ENTRY_LINE = /^ {2}\S/;
const TOP_LEVEL_LINE = /^\S/;
const WORKSPACE_PACKAGES_HEADER = /^packages\s*:\s*(?:#.*)?$/;
const WORKSPACE_ITEM_MARKER = '- ';
// A line that ends the `packages:` block: anything at column 0 other than a
// comment or a zero-indent sequence item.
const WORKSPACE_BLOCK_END = /^[^\s#-]/;

class StripRefusal extends Error {
  readonly detail: string;

  readonly file: 'lockfile' | 'workspace';

  readonly token: PnpmStripRefusal;

  constructor(
    file: 'lockfile' | 'workspace',
    token: PnpmStripRefusal,
    detail: string
  ) {
    super(`${token}: ${detail}`);
    this.detail = detail;
    this.file = file;
    this.token = token;
  }
}

const refuse = (
  file: 'lockfile' | 'workspace',
  token: PnpmStripRefusal,
  detail: string
): never => {
  throw new StripRefusal(file, token, detail);
};

const messageOf = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// Lockfile documents

type SplitLockfile = {
  dependencyDocument: string;
  packageManagerDocument: string;
  prefix: string;
};

const splitLockfile = (lockfile: string): SplitLockfile => {
  const lines = lockfile.split('\n');
  const starts = lines.flatMap((line, index) =>
    line === DOCUMENT_START ? [index] : []
  );
  const [first, second] = starts;

  if (starts.length !== 2 || first !== 0 || second === undefined) {
    return refuse(
      'lockfile',
      'unparseable',
      `expected exactly two YAML documents, each opened by a '${DOCUMENT_START}' line, found ${starts.length}`
    );
  }

  return {
    dependencyDocument: lines.slice(second + 1).join('\n'),
    packageManagerDocument: lines.slice(1, second).join('\n'),
    prefix: `${lines.slice(0, second + 1).join('\n')}\n`,
  };
};

const parseDocument = (
  text: string,
  label: string,
  schema?: typeof FAILSAFE_SCHEMA
): Record<string, unknown> => {
  let parsed: unknown;

  try {
    parsed = schema === undefined ? load(text) : load(text, {schema});
  } catch (error) {
    return refuse('lockfile', 'unparseable', `${label}: ${messageOf(error)}`);
  }

  return isRecord(parsed) ? parsed : (
      refuse('lockfile', 'unparseable', `${label} is not a YAML mapping`)
    );
};

const assertLockfileVersions = (split: SplitLockfile): void => {
  const documents = [
    ['document 1 (packageManagerDependencies)', split.packageManagerDocument],
    ['document 2 (dependencies)', split.dependencyDocument],
  ] as const;

  for (const [label, text] of documents) {
    const version = parseDocument(text, label).lockfileVersion;

    if (version !== SUPPORTED_LOCKFILE_VERSION) {
      refuse(
        'lockfile',
        'unknown-lockfile-version',
        `${label} declares lockfileVersion ${JSON.stringify(version)}; only '${SUPPORTED_LOCKFILE_VERSION}' is supported`
      );
    }
  }
};

// Dependency graph

type DependencyGraph = {
  importers: Map<string, Map<string, string>>;
  packageIds: ReadonlySet<string>;
  snapshots: Map<string, Map<string, string>>;
};

const sectionOf = (
  document: Record<string, unknown>,
  section: string
): Record<string, unknown> => {
  const value = document[section];

  if (value === undefined || value === null || value === '') return {};

  return isRecord(value) ? value : (
      refuse('lockfile', 'unparseable', `${section} is not a mapping`)
    );
};

type EdgeSource = {
  body: unknown;
  fields: readonly string[];
  owner: string;
  versionOf: (entry: unknown) => unknown;
};

const readEdges = ({
  body,
  fields,
  owner,
  versionOf,
}: EdgeSource): Map<string, string> => {
  const edges = new Map<string, string>();

  if (!isRecord(body)) return edges;

  for (const field of fields) {
    const dependencies = body[field];

    if (isRecord(dependencies)) {
      for (const [name, entry] of Object.entries(dependencies)) {
        const version = versionOf(entry);

        if (typeof version !== 'string' || version.length === 0) {
          refuse(
            'lockfile',
            'unparseable',
            `${owner} ${field}.${name} has no version string`
          );
        }

        edges.set(name, version as string);
      }
    }
  }

  return edges;
};

const buildGraph = (document: Record<string, unknown>): DependencyGraph => {
  const importers = new Map<string, Map<string, string>>();
  const snapshots = new Map<string, Map<string, string>>();

  for (const [key, body] of Object.entries(sectionOf(document, 'importers'))) {
    importers.set(
      key,
      readEdges({
        body,
        fields: IMPORTER_DEPENDENCY_FIELDS,
        owner: `importers.${key}`,
        versionOf: (entry) => (isRecord(entry) ? entry.version : undefined),
      })
    );
  }

  for (const [key, body] of Object.entries(sectionOf(document, 'snapshots'))) {
    snapshots.set(
      key,
      readEdges({
        body,
        fields: SNAPSHOT_DEPENDENCY_FIELDS,
        owner: `snapshots.${key}`,
        versionOf: (entry) => entry,
      })
    );
  }

  return {
    importers,
    packageIds: new Set(Object.keys(sectionOf(document, 'packages'))),
    snapshots,
  };
};

/**
 * The snapshot id a dependency value points at, or null for a workspace link
 * or local directory, which have no snapshot to follow.
 */
const dependencyTarget = (name: string, value: string): null | string => {
  if (value.startsWith('link:') || value.startsWith('file:')) return null;

  if (/^\d/.test(value)) return `${name}@${value}`;

  return ALIAS_VALUE.test(value) ? value : `${name}@${value}`;
};

const edgeTargets = (edges: ReadonlyMap<string, string>): string[] =>
  [...edges].flatMap(([name, value]) => {
    const target = dependencyTarget(name, value);

    return target === null ? [] : [target];
  });

/** A snapshot id with every `(...)` peer suffix removed: its packages key. */
const packageBase = (snapshotId: string): string => {
  const peerStart = snapshotId.indexOf('(', 1);

  return peerStart === -1 ? snapshotId : snapshotId.slice(0, peerStart);
};

const reachFrom = (
  graph: DependencyGraph,
  importerKeys: readonly string[]
): Set<string> => {
  const reached = new Set<string>();
  const pending: {from: string; id: string}[] = importerKeys.flatMap((key) =>
    edgeTargets(graph.importers.get(key) ?? new Map()).map((id) => ({
      from: `importers.${key}`,
      id,
    }))
  );

  for (let next = pending.pop(); next !== undefined; next = pending.pop()) {
    const {from, id} = next;

    if (!reached.has(id)) {
      const edges = graph.snapshots.get(id);

      if (edges === undefined) {
        refuse(
          'lockfile',
          'missing-snapshot',
          `${id} (referenced from ${from}) has no snapshots entry`
        );
      }

      reached.add(id);

      for (const target of edgeTargets(edges as Map<string, string>)) {
        pending.push({from: `snapshots.${id}`, id: target});
      }
    }
  }

  return reached;
};

const pruneView = (graph: DependencyGraph, member: string): PruneView => {
  const rest = [...graph.importers.keys()].filter((key) => key !== member);
  const memberEdges = graph.importers.get(member) ?? new Map();

  return {
    memberDependencyNames: new Set(memberEdges.keys()),
    memberReach: reachFrom(graph, [member]),
    restReach: reachFrom(graph, rest),
    snapshotIds: [...graph.snapshots.keys()],
  };
};

/** The shipped rule: reachable from the member and from no other importer. */
const memberOnlyPrune: PrunePolicy = ({memberReach, restReach}) =>
  new Set([...memberReach].filter((id) => !restReach.has(id)));

type PrunePlan = {packages: Set<string>; snapshots: Set<string>};

const planPrune = (
  graph: DependencyGraph,
  droppedSnapshots: ReadonlySet<string>
): PrunePlan => {
  const survivingBases = new Set(
    [...graph.snapshots.keys()]
      .filter((id) => !droppedSnapshots.has(id))
      .map((id) => packageBase(id))
  );
  const packages = new Set(
    [...droppedSnapshots]
      .map((id) => packageBase(id))
      .filter((base) => graph.packageIds.has(base) && !survivingBases.has(base))
  );

  return {
    packages,
    snapshots: new Set(
      [...droppedSnapshots].filter((id) => graph.snapshots.has(id))
    ),
  };
};

// Line locator

type EntrySpan = {end: number; key: string; section: string; start: number};

const alphabetical = (left: string, right: string): number =>
  left.localeCompare(right);

const sortedStrings = (values: Iterable<string>): string[] => {
  const copy: string[] = [...values];

  return copy.toSorted(alphabetical);
};

const parseEntryKey = (line: string, index: number): string => {
  let parsed: unknown;

  try {
    parsed = load(line.trim(), {schema: FAILSAFE_SCHEMA});
  } catch {
    parsed = undefined;
  }

  const keys = isRecord(parsed) ? Object.keys(parsed) : [];

  return keys.length === 1 ?
      (keys[0] as string)
    : refuse(
        'lockfile',
        'unparseable',
        `line ${index + 1} of the dependency document is not a single entry key`
      );
};

const assertSpansMatchDocument = (
  spans: ReadonlyMap<string, ReadonlyMap<string, EntrySpan>>,
  document: Record<string, unknown>
): void => {
  for (const name of ENTRY_SECTIONS) {
    const located = spans.get(name) ?? new Map<string, EntrySpan>();
    const parsed = Object.keys(sectionOf(document, name));

    if (
      located.size !== parsed.length ||
      !parsed.every((key) => located.has(key))
    ) {
      refuse(
        'lockfile',
        'unparseable',
        `the line locator found ${located.size} ${name} entries where the parsed document has ${parsed.length}`
      );
    }
  }
};

/**
 * Locates every importers/packages/snapshots entry as a line span, from its
 * key line to its last non-blank line, and proves the spans agree with the
 * parsed document so a line edit can never remove something the analysis did
 * not see.
 */
const locateEntries = (
  lines: readonly string[],
  document: Record<string, unknown>
): Map<string, Map<string, EntrySpan>> => {
  const spans = new Map<string, Map<string, EntrySpan>>(
    ENTRY_SECTIONS.map((section) => [section, new Map()])
  );
  let section: null | string = null;
  let current: EntrySpan | null = null;

  for (const [index, line] of lines.entries()) {
    if (line !== '') {
      if (TOP_LEVEL_LINE.test(line)) {
        current = null;
        section = line.slice(0, line.indexOf(':'));
      } else if (
        ENTRY_LINE.test(line) &&
        section !== null &&
        spans.has(section)
      ) {
        const key = parseEntryKey(line, index);
        const sectionSpans = spans.get(section) as Map<string, EntrySpan>;

        if (sectionSpans.has(key) || lines[index - 1] !== '') {
          refuse(
            'lockfile',
            'unparseable',
            `${section}.${key} at line ${index + 1} is duplicated or not preceded by a blank line`
          );
        }

        current = {end: index, key, section, start: index};
        sectionSpans.set(key, current);
      } else if (current !== null) {
        current.end = index;
      }
    }
  }

  assertSpansMatchDocument(spans, document);

  return spans;
};

const removeEntries = (
  dependencyDocument: string,
  document: Record<string, unknown>,
  removals: ReadonlyMap<string, ReadonlySet<string>>
): string => {
  const lines = dependencyDocument.split('\n');
  const spans = locateEntries(lines, document);
  const dropped = new Set<number>();

  for (const [section, keys] of removals) {
    const sectionSpans = spans.get(section) as Map<string, EntrySpan>;

    if (keys.size > 0 && keys.size >= sectionSpans.size) {
      refuse(
        'lockfile',
        'unparseable',
        `removing every ${section} entry leaves a shape this line edit cannot write`
      );
    }

    for (const key of keys) {
      const span = sectionSpans.get(key) as EntrySpan;

      // The blank separator pnpm writes before every entry goes with it, so
      // the surrounding entries keep exactly one blank line between them.
      for (let index = span.start - 1; index <= span.end; index += 1) {
        dropped.add(index);
      }
    }
  }

  return lines.filter((_, index) => !dropped.has(index)).join('\n');
};

// Workspace file

const readWorkspacePackages = (workspace: string): string[] => {
  let parsed: unknown;

  try {
    parsed = load(workspace);
  } catch (error) {
    return refuse('workspace', 'unparseable', messageOf(error));
  }

  const packages = isRecord(parsed) ? parsed.packages : undefined;

  if (packages === undefined || packages === null) return [];

  if (
    !Array.isArray(packages) ||
    !packages.every((item) => typeof item === 'string')
  ) {
    return refuse(
      'workspace',
      'unparseable',
      'packages is not a list of strings'
    );
  }

  return packages;
};

const parseItemValue = (text: string): unknown => {
  try {
    return load(text, {schema: FAILSAFE_SCHEMA});
  } catch {
    return undefined;
  }
};

/**
 * Removes the member's list item line, matched by its parsed value so a
 * quoted spelling or a trailing comment still matches and an exact-text
 * match cannot drift when pnpm writes the file back.
 */
const removeWorkspaceMember = (workspace: string, member: string): string => {
  const lines = workspace.split('\n');
  const headers = lines.flatMap((line, index) =>
    WORKSPACE_PACKAGES_HEADER.test(line) ? [index] : []
  );
  const [header] = headers;

  if (headers.length !== 1 || header === undefined) {
    return refuse(
      'workspace',
      'unparseable',
      'no single block-style packages key to edit'
    );
  }

  const matches: number[] = [];

  for (let index = header + 1; index < lines.length; index += 1) {
    const line = lines[index] as string;

    if (WORKSPACE_BLOCK_END.test(line)) break;

    const item = line.trimStart();

    if (
      item.startsWith(WORKSPACE_ITEM_MARKER) &&
      parseItemValue(item.slice(WORKSPACE_ITEM_MARKER.length)) === member
    ) {
      matches.push(index);
    }
  }

  if (matches.length !== 1) {
    return refuse(
      'workspace',
      'unparseable',
      `found ${matches.length} packages item lines for ${member}, expected exactly one`
    );
  }

  return lines.filter((_, index) => index !== matches[0]).join('\n');
};

// Strip

const toRefused = (error: unknown): Refused => {
  if (error instanceof StripRefusal) {
    return {
      detail: error.detail,
      file: error.file,
      kind: 'refused',
      token: error.token,
    };
  }

  return {
    detail: messageOf(error),
    file: 'lockfile',
    kind: 'refused',
    token: 'unparseable',
  };
};

const stripWith = (
  input: PnpmMemberStripInput,
  policy: PrunePolicy
): PnpmMemberStripOutcome => {
  const split = splitLockfile(input.lockfile);

  assertLockfileVersions(split);

  const document = parseDocument(
    split.dependencyDocument,
    'document 2 (dependencies)',
    FAILSAFE_SCHEMA
  );
  const listed = readWorkspacePackages(input.workspace).filter(
    (item) => item === input.member
  );
  const graph = buildGraph(document);
  const hasImporter = graph.importers.has(input.member);

  if (listed.length > 1) {
    refuse('workspace', 'unparseable', `packages lists ${input.member} twice`);
  }

  if (listed.length === 0 && !hasImporter) return {kind: 'noop'};

  if (!hasImporter) {
    refuse(
      'workspace',
      'member-without-importer',
      `packages lists ${input.member} but the lockfile has no importers entry for it`
    );
  }

  if (listed.length === 0) {
    refuse(
      'lockfile',
      'importer-without-member',
      `importers has an entry for ${input.member} but the workspace packages list does not name it`
    );
  }

  const plan = planPrune(graph, policy(pruneView(graph, input.member)));
  const dependencyDocument = removeEntries(
    split.dependencyDocument,
    document,
    new Map([
      ['importers', new Set([input.member])],
      ['packages', plan.packages],
      ['snapshots', plan.snapshots],
    ])
  );

  return {
    kind: 'stripped',
    lockfile: `${split.prefix}${dependencyDocument}`,
    removed: {
      importers: [input.member],
      packages: sortedStrings(plan.packages),
      snapshots: sortedStrings(plan.snapshots),
    },
    workspace: removeWorkspaceMember(input.workspace, input.member),
  };
};

/**
 * The strip under a caller-chosen prune policy, without the self-check. A
 * test seam for proving the golden fixtures reject a wrong policy; release
 * code calls `stripPnpmMember`.
 */
export const stripPnpmMemberUnchecked = (
  input: PnpmMemberStripInput,
  policy: PrunePolicy
): PnpmMemberStripOutcome => {
  try {
    return stripWith(input, policy);
  } catch (error) {
    return toRefused(error);
  }
};

// Self-check

const parseDependencyDocument = (lockfile: string): DependencyGraph =>
  buildGraph(
    parseDocument(
      splitLockfile(lockfile).dependencyDocument,
      'document 2 (dependencies)',
      FAILSAFE_SCHEMA
    )
  );

const memberOnlyKeys = (
  graph: DependencyGraph,
  member: string
): {packages: Set<string>; snapshots: Set<string>} =>
  graph.importers.has(member) ?
    planPrune(graph, memberOnlyPrune(pruneView(graph, member)))
  : {packages: new Set(), snapshots: new Set()};

/**
 * Keys in `after` that were reachable only from `member` in `before`: the
 * importer itself, its member-only snapshots, and the packages entries those
 * snapshots alone held. Empty means nothing CLI-only survived.
 */
export const findMemberOnlyLeftovers = ({
  after,
  before,
  member,
}: {
  after: string;
  before: string;
  member: string;
}): string[] => {
  const beforeGraph = parseDependencyDocument(before);
  const afterGraph = parseDependencyDocument(after);
  const memberOnly = memberOnlyKeys(beforeGraph, member);

  return sortedStrings([
    ...(afterGraph.importers.has(member) ? [`importers[${member}]`] : []),
    ...[...memberOnly.packages]
      .filter((key) => afterGraph.packageIds.has(key))
      .map((key) => `packages[${key}]`),
    ...[...memberOnly.snapshots]
      .filter((key) => afterGraph.snapshots.has(key))
      .map((key) => `snapshots[${key}]`),
  ]);
};

const danglingReferences = (graph: DependencyGraph): Set<string> => {
  const dangling = new Set<string>();
  const owners: [string, Map<string, string>][] = [
    ...[...graph.importers].map(
      ([key, edges]): [string, Map<string, string>] => [
        `importers.${key}`,
        edges,
      ]
    ),
    ...[...graph.snapshots].map(
      ([key, edges]): [string, Map<string, string>] => [
        `snapshots.${key}`,
        edges,
      ]
    ),
  ];

  for (const [owner, edges] of owners) {
    for (const target of edgeTargets(edges)) {
      if (!graph.snapshots.has(target)) dangling.add(`${owner} -> ${target}`);
    }
  }

  return dangling;
};

const snapshotsWithoutPackage = (graph: DependencyGraph): Set<string> =>
  new Set(
    [...graph.snapshots.keys()].filter(
      (id) => !graph.packageIds.has(packageBase(id))
    )
  );

const packagesWithoutSnapshot = (graph: DependencyGraph): Set<string> => {
  const bases = new Set(
    [...graph.snapshots.keys()].map((id) => packageBase(id))
  );

  return new Set([...graph.packageIds].filter((key) => !bases.has(key)));
};

const newIn = (
  after: ReadonlySet<string>,
  before: ReadonlySet<string>
): string[] => sortedStrings([...after].filter((item) => !before.has(item)));

const integrityProblems = (
  beforeGraph: DependencyGraph,
  afterGraph: DependencyGraph
): string[] => [
  ...newIn(danglingReferences(afterGraph), danglingReferences(beforeGraph)).map(
    (reference) => `dangling reference ${reference}`
  ),
  ...newIn(
    snapshotsWithoutPackage(afterGraph),
    snapshotsWithoutPackage(beforeGraph)
  ).map((id) => `snapshots[${id}] has no packages entry`),
  ...newIn(
    packagesWithoutSnapshot(afterGraph),
    packagesWithoutSnapshot(beforeGraph)
  ).map((key) => `packages[${key}] has no snapshot`),
];

const checkWorkspace = (input: PnpmMemberStripInput, workspace: string) => {
  const expected = readWorkspacePackages(input.workspace).filter(
    (item) => item !== input.member
  );
  const actual = readWorkspacePackages(workspace);

  if (actual.join('\n') !== expected.join('\n')) {
    refuse(
      'workspace',
      'integrity',
      `packages is [${actual.join(', ')}], expected [${expected.join(', ')}]`
    );
  }
};

const checkPair = (input: PnpmMemberStripInput, stripped: Stripped): void => {
  checkWorkspace(input, stripped.workspace);

  if (
    splitLockfile(stripped.lockfile).prefix !==
    splitLockfile(input.lockfile).prefix
  ) {
    refuse(
      'lockfile',
      'integrity',
      'document 1 (packageManagerDependencies) changed'
    );
  }

  const leftovers = findMemberOnlyLeftovers({
    after: stripped.lockfile,
    before: input.lockfile,
    member: input.member,
  });

  if (leftovers.length > 0) {
    refuse('lockfile', 'cli-only-key-survives', leftovers.join(', '));
  }

  const problems = integrityProblems(
    parseDependencyDocument(input.lockfile),
    parseDependencyDocument(stripped.lockfile)
  );

  if (problems.length > 0) refuse('lockfile', 'integrity', problems.join('; '));
};

/**
 * Verifies a stripped pair against its input: document 1 untouched, the
 * workspace list minus exactly the member, no member-only key left, and no
 * new dangling reference or packages/snapshots mismatch. Returns the refusal,
 * or null when the pair is consistent.
 */
export const checkStrippedPair = (
  input: PnpmMemberStripInput,
  stripped: Stripped
): null | Refused => {
  try {
    checkPair(input, stripped);

    return null;
  } catch (error) {
    return toRefused(error);
  }
};

/** Removes `member` from a pnpm v9 workspace file and lockfile pair. */
export const stripPnpmMember = (
  input: PnpmMemberStripInput
): PnpmMemberStripOutcome => {
  const outcome = stripPnpmMemberUnchecked(input, memberOnlyPrune);

  if (outcome.kind !== 'stripped') return outcome;

  return checkStrippedPair(input, outcome) ?? outcome;
};
