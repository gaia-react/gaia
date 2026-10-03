import {z} from 'zod';
/**
 * The TypeScript reader of the package registry and descriptors (SPEC-092
 * contract C1 to C4). One of three implementations of one contract: the bash
 * twin is `.claude/hooks/lib/gaia-packages.sh`, the Node twin is
 * `.gaia/scripts/lib/gaia-packages.mjs`. The shared conformance corpus under
 * `.gaia/tests/fixtures/gaia-packages/` is the oracle all three satisfy, error
 * message text included, so a reason string changed here changes in the other
 * two.
 *
 * Fail-closed: an absent `.gaia/packages.json` is the built-in default
 * (frontend at `frontend`), never "nothing in scope"; a present registry that
 * is malformed, or a descriptor that is missing or invalid, returns an error
 * result and never a partial answer.
 *
 * Glob dialect (C3): `**` + `/` is zero or more whole directories, a trailing
 * `/**` is everything beneath, `*` is any run excluding `/`, `?` is one
 * character excluding `/`, `{a,b}` is non-nested alternation, every other
 * character is literal. A glob compiles through control-character sentinels so
 * a single `*` is never re-read as half of `**`; descriptor strings carrying
 * control characters are refused by the schema, which keeps those sentinels
 * private.
 */
import {lstatSync, readFileSync} from 'node:fs';
import path from 'node:path';

const REGISTRY_FILE = '.gaia/packages.json';
const DESCRIPTOR_NAME = 'gaia.package.json';
const NAME_PATTERN = /^[a-z][a-z0-9-]*$/;
const PATH_PATTERN = /^(\.|[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)*)$/;
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTER = /[\u0000-\u001F\u007F]/;

/** The `globs` keys every descriptor must carry, in validation order. */
export const GLOB_KEYS = [
  'tddUnitTests',
  'tddStrictCandidates',
  'emergentTests',
  'selfHealRefuse',
  'preCommitSource',
  'doctorConfigs',
  'dependencyManifests',
] as const;

export type GlobKey = (typeof GLOB_KEYS)[number];

const cleanString = z
  .string()
  .min(1)
  .refine((value) => !CONTROL_CHARACTER.test(value));
const globList = z.array(cleanString).min(1);
const wikiList = z.array(z.string().refine((v) => !CONTROL_CHARACTER.test(v)));

export const registryEntrySchema = z.object({
  name: z.string().regex(NAME_PATTERN),
  path: z.string().regex(PATH_PATTERN),
});

export const registrySchema = z.array(registryEntrySchema);

export const descriptorSchema = (expectedName: string) =>
  z.object({
    globs: z.object({
      dependencyManifests: globList,
      doctorConfigs: globList,
      emergentTests: globList,
      preCommitSource: globList,
      selfHealRefuse: globList,
      tddStrictCandidates: globList,
      tddUnitTests: globList,
    }),
    name: z.literal(expectedName),
    schemaVersion: z.literal(1),
    wiki: z.object({
      flowPaths: wikiList,
      inventoryPaths: wikiList,
      sourcePaths: wikiList,
    }),
  });

export type LoadedPackage = RegistryEntry & {descriptor: PackageDescriptor};

export type LoadResult =
  | {
      code: 'DESCRIPTOR_INVALID' | 'REGISTRY_MALFORMED';
      message: string;
      ok: false;
    }
  | {ok: true; packages: LoadedPackage[]; source: 'builtin' | 'registry'};

export type PackageDescriptor = z.infer<ReturnType<typeof descriptorSchema>>;

export type RegistryEntry = z.infer<typeof registryEntrySchema>;

export const BUILTIN_REGISTRY: readonly RegistryEntry[] = [
  {name: 'frontend', path: 'frontend'},
];

export const BUILTIN_DESCRIPTOR: PackageDescriptor = {
  globs: {
    dependencyManifests: ['package.json'],
    doctorConfigs: ['doctor.config.*', 'react-doctor.config.*'],
    emergentTests: [
      'app/components/**/*.test.ts',
      'app/components/**/*.test.tsx',
      '.playwright/**/*.spec.ts',
      '.playwright/**/*.spec.tsx',
      '.playwright/**/*.test.ts',
      '.playwright/**/*.test.tsx',
    ],
    preCommitSource: ['app/**', 'test/**', '.storybook/**', '.playwright/**'],
    selfHealRefuse: [
      '.claude/**',
      'CLAUDE.md',
      'gaia.package.json',
      'test/**',
      '.playwright/**',
      '.storybook/**',
      'app/**/tests/**',
      'app/**/*.test.ts',
      'app/**/*.test.tsx',
      'app/**/*.stories.tsx',
      'package.json',
      'tsconfig*.json',
      '*.config.ts',
      '*.config.mts',
      '*.config.mjs',
      '*.config.cjs',
      '*.config.js',
      'Dockerfile',
      'Dockerfile.dockerignore',
      '.*',
    ],
    tddStrictCandidates: [
      'app/utils/**',
      'app/services/**',
      'app/hooks/**',
      'app/components/**/*.ts',
    ],
    tddUnitTests: ['app/**/*.test.ts', 'app/**/*.test.tsx'],
  },
  name: 'frontend',
  schemaVersion: 1,
  wiki: {
    flowPaths: [
      'app/middleware/',
      'app/routes.ts',
      'app/i18n.ts',
      'app/sessions.server/',
    ],
    inventoryPaths: [
      'app/components/',
      'app/hooks/',
      'app/pages/',
      'app/services/',
    ],
    sourcePaths: ['app/'],
  },
};

const registryError = (reason: string): LoadResult => {
  const detail = reason === '' ? '' : `: ${reason}`;

  return {
    code: 'REGISTRY_MALFORMED',
    message: `gaia-packages: ${REGISTRY_FILE} is malformed${detail}. Next step: fix ${REGISTRY_FILE} so it is a JSON array of {"name","path"} entries, or delete it to use the built-in default.`,
    ok: false,
  };
};

const descriptorError = (
  file: string,
  state: 'invalid' | 'malformed' | 'missing',
  reason = ''
): LoadResult => {
  const nextStep =
    state === 'missing' ?
      `restore ${file} from the GAIA release, or correct the path in ${REGISTRY_FILE}`
    : `restore ${file} from the GAIA release, or correct the field it names`;
  const status = state === 'invalid' ? `invalid: ${reason}` : state;

  return {
    code: 'DESCRIPTOR_INVALID',
    message: `gaia-packages: ${file} is ${status}. Next step: ${nextStep}.`,
    ok: false,
  };
};

const descriptorFileFor = (packagePath: string): string =>
  packagePath === '.' ? DESCRIPTOR_NAME : `${packagePath}/${DESCRIPTOR_NAME}`;

/** The reason a registry that failed the schema is malformed, from its first issue. */
const registryIssueReason = (issue: z.core.$ZodIssue): string => {
  const [index, field] = issue.path;

  if (index === undefined) {
    return 'not a JSON array';
  }

  if (field === undefined) {
    return `entry ${String(index)} is not an object`;
  }

  return `entry ${String(index)} ${String(field)} is invalid`;
};

/** The reason a registry that passed the schema is malformed anyway: a repeat. */
const duplicateReason = (entries: RegistryEntry[]): null | string => {
  const names = new Set<string>();
  const paths = new Set<string>();

  for (const [index, entry] of entries.entries()) {
    if (names.has(entry.name)) {
      return `entry ${String(index)} name is a duplicate`;
    }

    if (paths.has(entry.path)) {
      return `entry ${String(index)} path is a duplicate`;
    }
    names.add(entry.name);
    paths.add(entry.path);
  }

  return null;
};

const SECTION_ORDER = ['schemaVersion', 'name', 'globs', 'wiki'];
const WIKI_KEY_ORDER = ['sourcePaths', 'inventoryPaths', 'flowPaths'];

/**
 * Where an issue falls in the validation order the bash and Node readers use.
 * Zod reports issues in schema key order, which the lint config sorts
 * alphabetically, so the order that picks the reported reason is stated here
 * rather than inherited from how the schema happens to be written.
 */
const issueRank = (issue: z.core.$ZodIssue): number => {
  const [section, key] = issue.path;
  const sectionRank = SECTION_ORDER.indexOf(String(section));
  const keyOrder = section === 'wiki' ? WIKI_KEY_ORDER : [...GLOB_KEYS];
  const keyRank = key === undefined ? -1 : keyOrder.indexOf(String(key));

  return (section === undefined ? -1 : sectionRank) * 100 + keyRank;
};

const descriptorIssueReason = (
  issue: z.core.$ZodIssue,
  expectedName: string
): string => {
  const [section, key] = issue.path;

  if (section === undefined) {
    return 'not a JSON object';
  }

  if (section === 'schemaVersion') {
    return 'schemaVersion must be 1';
  }

  if (section === 'name') {
    return `name must be "${expectedName}"`;
  }

  if (section === 'globs') {
    return key === undefined ?
        'globs must be an object'
      : `globs.${String(key)} must be a non-empty array of non-empty strings without control characters`;
  }

  return key === undefined ?
      'wiki must be an object'
    : `wiki.${String(key)} must be an array of strings without control characters`;
};

type FileState =
  {kind: 'absent'} | {kind: 'text'; text: string} | {kind: 'unreadable'};

// A dangling symlink counts as present and unreadable, never as absent, so a
// broken link cannot select the built-in default.
const readFileState = (file: string): FileState => {
  try {
    lstatSync(file);
  } catch (error) {
    return {
      kind:
        (error as NodeJS.ErrnoException).code === 'ENOENT' ?
          'absent'
        : 'unreadable',
    };
  }

  try {
    return {kind: 'text', text: readFileSync(file, 'utf8')};
  } catch {
    return {kind: 'unreadable'};
  }
};

const parseJson = (state: FileState): null | {value: unknown} => {
  if (state.kind !== 'text') {
    return null;
  }

  try {
    return {value: JSON.parse(state.text) as unknown};
  } catch {
    return null;
  }
};

const loadRegistry = (
  repoRoot: string
):
  | LoadResult
  | {entries: readonly RegistryEntry[]; source: 'builtin' | 'registry'} => {
  const read = readFileState(path.join(repoRoot, REGISTRY_FILE));

  if (read.kind === 'absent') {
    return {entries: BUILTIN_REGISTRY, source: 'builtin'};
  }
  const parsed = parseJson(read);

  if (parsed === null) {
    return registryError('');
  }
  const registry = registrySchema.safeParse(parsed.value);

  if (!registry.success) {
    const [issue] = registry.error.issues;

    return registryError(
      issue === undefined ? 'not a JSON array' : registryIssueReason(issue)
    );
  }
  const duplicate = duplicateReason(registry.data);

  return duplicate === null ?
      {entries: registry.data, source: 'registry'}
    : registryError(duplicate);
};

const loadDescriptor = (
  repoRoot: string,
  entry: RegistryEntry
): LoadedPackage | LoadResult => {
  const file = descriptorFileFor(entry.path);
  const read = readFileState(path.join(repoRoot, file));

  if (read.kind === 'absent') {
    return descriptorError(file, 'missing');
  }
  const parsed = parseJson(read);

  if (parsed === null) {
    return descriptorError(file, 'malformed');
  }
  const descriptor = descriptorSchema(entry.name).safeParse(parsed.value);

  if (descriptor.success) {
    return {...entry, descriptor: descriptor.data};
  }
  const [issue] = descriptor.error.issues.toSorted(
    (a, b) => issueRank(a) - issueRank(b)
  );
  const reason =
    issue === undefined ? 'not a JSON object' : (
      descriptorIssueReason(issue, entry.name)
    );

  return descriptorError(file, 'invalid', reason);
};

export const loadPackages = (repoRoot: string): LoadResult => {
  const registry = loadRegistry(repoRoot);

  if ('ok' in registry) {
    return registry;
  }

  if (registry.source === 'builtin') {
    return {
      ok: true,
      packages: registry.entries.map((entry) => ({
        ...entry,
        descriptor: BUILTIN_DESCRIPTOR,
      })),
      source: 'builtin',
    };
  }
  const packages: LoadedPackage[] = [];

  for (const entry of registry.entries) {
    const loaded = loadDescriptor(repoRoot, entry);

    if ('ok' in loaded) {
      return loaded;
    }
    packages.push(loaded);
  }

  return {ok: true, packages, source: 'registry'};
};

/**
 * The ERE-grammar body of a glob, without anchors. Sentinels: \u0001 for the
 * zero-or-more-directories form, \u0002 for `**`, \u0003 for `*`, \u0004 for
 * `?`, \u0005 and \u0006 for a brace group's parentheses, \u0007 for its bar.
 */
export const globToBody = (glob: string): string =>
  glob
    .replaceAll(/[\\.+^$()[\]|]/g, String.raw`\$&`)
    .replaceAll('**/', '\u0001')
    .replaceAll('**', '\u0002')
    .replaceAll('*', '\u0003')
    .replaceAll('?', '\u0004')
    .replaceAll(
      /\{([^{}]+)\}/g,
      (_match, inner: string) =>
        `\u0005${inner.replaceAll(',', '\u0007')}\u0006`
    )
    .replaceAll(/[{}]/g, String.raw`\$&`)
    .replaceAll('\u0001', '(.*/)?')
    .replaceAll('\u0002', '.*')
    .replaceAll('\u0003', '[^/]*')
    .replaceAll('\u0004', '[^/]')
    .replaceAll('\u0005', '(')
    .replaceAll('\u0006', ')')
    .replaceAll('\u0007', '|');

export const globToRegExp = (glob: string): RegExp =>
  new RegExp(`^${globToBody(glob)}$`);

export const joinGlob = (packagePath: string, glob: string): string =>
  packagePath === '.' ? glob : `${packagePath}/${glob}`;

export const repoRegExps = (
  packages: readonly LoadedPackage[],
  key: GlobKey
): RegExp[] =>
  packages.flatMap((entry) =>
    entry.descriptor.globs[key].map((glob) =>
      globToRegExp(joinGlob(entry.path, glob))
    )
  );

/**
 * The package whose directory is the longest prefix of the path; a package at
 * `.` owns every path no deeper package claims.
 */
export const packageForPath = (
  packages: readonly LoadedPackage[],
  repoRelativePath: string
): LoadedPackage | null => {
  let best: LoadedPackage | null = null;
  let bestLength = -1;

  for (const entry of packages) {
    const prefixLength = entry.path === '.' ? 0 : entry.path.length;
    const owns =
      entry.path === '.' ||
      repoRelativePath === entry.path ||
      repoRelativePath.startsWith(`${entry.path}/`);

    if (owns && prefixLength > bestLength) {
      best = entry;
      bestLength = prefixLength;
    }
  }

  return best;
};

/**
 * Absolute path of a package directory, resolved against `repoRoot` and never
 * the working directory. Throws when the registry cannot be loaded or names no
 * such package, so a caller never builds a path from a guess.
 */
export const packageRoot = (repoRoot: string, name = 'frontend'): string => {
  const loaded = loadPackages(repoRoot);

  if (!loaded.ok) {
    throw new Error(loaded.message);
  }
  const found = loaded.packages.find((entry) => entry.name === name);

  if (found === undefined) {
    throw new Error(
      `gaia-packages: no package named "${name}" is registered. Next step: add it to ${REGISTRY_FILE}.`
    );
  }

  return path.resolve(repoRoot, found.path);
};
