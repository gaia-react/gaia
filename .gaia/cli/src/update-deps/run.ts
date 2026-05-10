/**
 * `gaia update-deps run --emit-updates <path>` handler.
 *
 * Replicates Phases 1-3 of `.claude/skills/update-deps/SKILL.md` as a
 * deterministic shell primitive so the GAIA CI workflow can split major
 * bumps into per-group PRs before dispatching the LLM-driven flow.
 *
 * Phase 1: Discover via `pnpm outdated --json`. ESLint 9.x cap rewrites
 *          a `latest >= 10.x` to the highest available `9.x`; if already
 *          on the highest 9.x, the entry is dropped silently.
 * Phase 2: Map each outdated package to its companion group via
 *          `groups.ts`. Packages with no rule become `singleton:<name>`.
 * Phase 3: Classify each group: any major bump → Wave B (per-group PR),
 *          else Wave A (batched). Groups with one major member pull all
 *          outdated siblings along — so the group moves together.
 *
 * Output: a JSON payload at the path passed to `--emit-updates`. The
 * shape is fixed and shared with the workflow template author. Schema in
 * the README of the surrounding PR; mirrored as a type below.
 */
import {spawnSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveGroup} from './groups.js';

export {resolveGroup} from './groups.js';

const HELP_TEXT = `Usage: gaia update-deps run --emit-updates <path>

  Discover outdated packages via \`pnpm outdated --json\`, classify each
  into Wave A (minor/patch, batched) or Wave B (major, per-group), and
  write the result as JSON to <path>. Used by the dependabot workflow to
  split major bumps into separate PRs before invoking the LLM upgrade.

  --emit-updates <path>   Required. JSON file to write. Parent dirs are
                          created on demand.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type Kind = 'major' | 'minor' | 'patch';

export type WaveAEntry = {
  current: string;
  group: string;
  is_pinned: boolean;
  kind: 'minor' | 'patch';
  latest: string;
  name: string;
  wanted: string;
};

export type WaveBPackage = {
  current: string;
  is_pinned: boolean;
  kind: Kind;
  latest: string;
  name: string;
  wanted: string;
};

export type WaveBGroup = {
  group: string;
  packages: readonly WaveBPackage[];
};

export type SkippedEntry = {
  current: string;
  latest: string;
  name: string;
  reason: string;
};

export type UpdatesPayload = {
  generated_at: string;
  schema_version: 1;
  skipped: readonly SkippedEntry[];
  wave_a: readonly WaveAEntry[];
  wave_b: readonly WaveBGroup[];
};

// ---------- pnpm runner indirection ----------

export type PnpmResult = {
  status: number | null;
  stderr: string;
  stdout: string;
};

export type PnpmRunner = (
  args: readonly string[],
  options: {cwd: string}
) => PnpmResult;

const defaultPnpmRunner: PnpmRunner = (args, options) => {
  const result = spawnSync('pnpm', args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  return {
    status: result.status,
    stderr: result.stderr ?? '',
    stdout: result.stdout ?? '',
  };
};

// ---------- version parsing ----------

/**
 * Strip leading range operators (`^`, `~`, `>=`, `>`, `=`, `v`) so we can
 * compare leading numeric segments. Whitespace is trimmed too.
 */
const stripRange = (raw: string): string => {
  let value = raw.trim();

  while (value.length > 0) {
    const first = value[0];

    if (first === '^' || first === '~' || first === '=' || first === 'v') {
      value = value.slice(1);
      continue;
    }

    if (first === '>' || first === '<') {
      value = value.slice(1);
      // strip an optional `=` after `>`/`<`
      if (value.startsWith('=')) value = value.slice(1);
      continue;
    }

    break;
  }

  return value.trim();
};

const parseSegments = (raw: string): readonly number[] => {
  const cleaned = stripRange(raw);
  // Take only the dot-separated leading numeric part. `1.2.3-beta.1` →
  // `[1, 2, 3]`. Non-numeric chunks beyond the first three slots are
  // ignored — the SKILL only needs leading-integer comparison.
  const parts = cleaned.split(/[+-]/u)[0]?.split('.') ?? [];
  const out: number[] = [];

  for (const part of parts) {
    const parsed = Number.parseInt(part, 10);

    out.push(Number.isFinite(parsed) ? parsed : 0);
  }

  while (out.length < 3) out.push(0);

  return out;
};

/**
 * Compare current/latest by leading segments. Major if `[0]` differs,
 * else minor if `[1]` differs, else patch. Matches the SKILL's
 * "compare leading integers" rule.
 */
export const classifyKind = (current: string, latest: string): Kind => {
  const a = parseSegments(current);
  const b = parseSegments(latest);

  if ((a[0] ?? 0) !== (b[0] ?? 0)) return 'major';
  if ((a[1] ?? 0) !== (b[1] ?? 0)) return 'minor';

  return 'patch';
};

const compareSegments = (a: readonly number[], b: readonly number[]): number => {
  const len = Math.max(a.length, b.length);

  for (let i = 0; i < len; i += 1) {
    const av = a[i] ?? 0;
    const bv = b[i] ?? 0;

    if (av !== bv) return av < bv ? -1 : 1;
  }

  return 0;
};

// ---------- pinning detection ----------

type PackageJsonShape = {
  dependencies?: Readonly<Record<string, string>>;
  devDependencies?: Readonly<Record<string, string>>;
  optionalDependencies?: Readonly<Record<string, string>>;
  peerDependencies?: Readonly<Record<string, string>>;
};

const readPackageJson = (cwd: string): PackageJsonShape => {
  const raw = readFileSync(path.join(cwd, 'package.json'), 'utf8');

  return JSON.parse(raw) as PackageJsonShape;
};

const lookupSpec = (pkg: PackageJsonShape, name: string): string | undefined =>
  pkg.dependencies?.[name] ??
  pkg.devDependencies?.[name] ??
  pkg.optionalDependencies?.[name] ??
  pkg.peerDependencies?.[name];

/**
 * Pinning rule per SKILL: no `^` or `~` prefix in the spec. Anything else
 * (exact `1.2.3`, `>=`, tag refs, etc.) counts as pinned.
 */
const isPinnedSpec = (spec: string | undefined): boolean => {
  if (spec === undefined) return false;

  const trimmed = spec.trim();

  if (trimmed.length === 0) return false;
  if (trimmed.startsWith('^')) return false;
  if (trimmed.startsWith('~')) return false;

  return true;
};

// ---------- pnpm outdated parsing ----------

type OutdatedRaw = {
  current: string;
  dependencyType?: string;
  latest: string;
  wanted: string;
};

type OutdatedEntry = {
  current: string;
  latest: string;
  name: string;
  wanted: string;
};

const parseOutdated = (
  stdout: string
): readonly OutdatedEntry[] => {
  const trimmed = stdout.trim();

  if (trimmed.length === 0) return [];

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return [];
  }

  if (parsed === null || typeof parsed !== 'object') return [];

  const out: OutdatedEntry[] = [];

  for (const [name, raw] of Object.entries(parsed as Record<string, unknown>)) {
    if (raw === null || typeof raw !== 'object') continue;

    const obj = raw as Partial<OutdatedRaw>;

    if (
      typeof obj.current !== 'string' ||
      typeof obj.latest !== 'string'
    ) {
      continue;
    }

    out.push({
      current: obj.current,
      latest: obj.latest,
      name,
      wanted: typeof obj.wanted === 'string' ? obj.wanted : obj.current,
    });
  }

  // Stable order: alphabetical by name. Makes the emitted JSON
  // deterministic across runs regardless of pnpm's output ordering.
  return [...out].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
};

// ---------- ESLint 9.x cap ----------

const ESLINT_CAPPED = new Set(['eslint', '@eslint/js']);

const findHighest9x = (versions: readonly string[]): string | undefined => {
  let best: {raw: string; segments: readonly number[]} | undefined;

  for (const candidate of versions) {
    const segments = parseSegments(candidate);

    if (segments[0] !== 9) continue;

    if (best === undefined || compareSegments(segments, best.segments) > 0) {
      best = {raw: candidate, segments};
    }
  }

  return best?.raw;
};

const fetchEslintVersions = (
  cwd: string,
  pnpmRunner: PnpmRunner
): readonly string[] => {
  const result = pnpmRunner(['view', 'eslint', 'versions', '--json'], {cwd});

  if (result.status !== 0) return [];

  const trimmed = result.stdout.trim();

  if (trimmed.length === 0) return [];

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) return [];

  return parsed.filter((value): value is string => typeof value === 'string');
};

type CappedDecision =
  | {kind: 'drop'}
  | {kind: 'pass'}
  | {kind: 'rewrite'; latest: string};

const applyEslintCap = (
  entry: OutdatedEntry,
  pnpmRunner: PnpmRunner,
  cwd: string,
  cache: {versions?: readonly string[]}
): CappedDecision => {
  if (!ESLINT_CAPPED.has(entry.name)) return {kind: 'pass'};

  const latestSegments = parseSegments(entry.latest);

  if ((latestSegments[0] ?? 0) < 10) return {kind: 'pass'};

  if (cache.versions === undefined) {
    cache.versions = fetchEslintVersions(cwd, pnpmRunner);
  }

  const highest9x = findHighest9x(cache.versions);

  if (highest9x === undefined) {
    // Cap requested but no 9.x line exists upstream — drop the entry to
    // avoid surfacing it. Adopters know about the cap; surfacing is noise.
    return {kind: 'drop'};
  }

  const currentSegments = parseSegments(entry.current);

  if (compareSegments(currentSegments, parseSegments(highest9x)) >= 0) {
    return {kind: 'drop'};
  }

  return {kind: 'rewrite', latest: highest9x};
};

// ---------- compute ----------

export type ComputeOptions = {
  cwd: string;
  pnpmRunner?: PnpmRunner;
};

type Adjusted = {
  current: string;
  group: string;
  is_pinned: boolean;
  kind: Kind;
  latest: string;
  name: string;
  wanted: string;
};

export const computeUpdates = (options: ComputeOptions): UpdatesPayload => {
  const pnpmRunner = options.pnpmRunner ?? defaultPnpmRunner;
  const pkg = readPackageJson(options.cwd);

  // pnpm outdated exits 1 when packages are outdated — that is normal.
  // We ignore the exit code and parse stdout regardless. Empty / invalid
  // stdout falls through to an empty entry list.
  const result = pnpmRunner(['outdated', '--json'], {cwd: options.cwd});
  const raw = parseOutdated(result.stdout);

  const eslintCache: {versions?: readonly string[]} = {};
  const adjusted: Adjusted[] = [];

  for (const entry of raw) {
    const decision = applyEslintCap(entry, pnpmRunner, options.cwd, eslintCache);

    if (decision.kind === 'drop') continue;

    const effectiveLatest =
      decision.kind === 'rewrite' ? decision.latest : entry.latest;
    const kind = classifyKind(entry.current, effectiveLatest);

    if (kind === 'patch' && entry.current === effectiveLatest) {
      // Already up to date after cap rewrite. Defensive — applyEslintCap's
      // drop branch already handles "already on highest 9.x", but a
      // best-of belt-and-suspenders guard for non-eslint paths.
      continue;
    }

    adjusted.push({
      current: entry.current,
      group: resolveGroup(entry.name),
      is_pinned: isPinnedSpec(lookupSpec(pkg, entry.name)),
      kind,
      latest: effectiveLatest,
      name: entry.name,
      wanted: entry.wanted,
    });
  }

  // Bucket by group. A group lands in Wave B if any member is major;
  // otherwise every member becomes a Wave A row (singletons stay
  // singletons, but companion groups stay grouped — we expose them as
  // separate Wave A rows since Wave A is batched into one install anyway).
  const byGroup = new Map<string, Adjusted[]>();

  for (const entry of adjusted) {
    const list = byGroup.get(entry.group);

    if (list === undefined) byGroup.set(entry.group, [entry]);
    else list.push(entry);
  }

  const waveA: WaveAEntry[] = [];
  const waveB: WaveBGroup[] = [];

  for (const [group, members] of byGroup) {
    const hasMajor = members.some((member) => member.kind === 'major');

    if (hasMajor) {
      const sorted = [...members].sort((a, b) =>
        a.name < b.name ? -1 : a.name > b.name ? 1 : 0
      );

      waveB.push({
        group,
        packages: sorted.map((member) => ({
          current: member.current,
          is_pinned: member.is_pinned,
          kind: member.kind,
          latest: member.latest,
          name: member.name,
          wanted: member.wanted,
        })),
      });
    } else {
      for (const member of members) {
        // Wave A entries can only be minor or patch — narrow the type.
        if (member.kind === 'major') continue;

        waveA.push({
          current: member.current,
          group: member.group,
          is_pinned: member.is_pinned,
          kind: member.kind,
          latest: member.latest,
          name: member.name,
          wanted: member.wanted,
        });
      }
    }
  }

  // Stable, alphabetical ordering for both waves.
  waveA.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  waveB.sort((a, b) => (a.group < b.group ? -1 : a.group > b.group ? 1 : 0));

  return {
    generated_at: new Date().toISOString(),
    schema_version: 1,
    skipped: [],
    wave_a: waveA,
    wave_b: waveB,
  };
};

// ---------- argv parsing ----------

type ParsedArgs = {
  emitUpdates: string;
};

type ParseError = {error: string};

const parseArgs = (argv: readonly string[]): ParsedArgs | ParseError => {
  let emitUpdates: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--emit-updates') {
      const value = argv[index + 1];

      if (value === undefined || value.length === 0) {
        return {error: '--emit-updates requires a path'};
      }
      emitUpdates = value;
      index += 1;
      continue;
    }

    return {error: `unknown flag: ${token ?? ''}`};
  }

  if (emitUpdates === undefined) {
    return {error: '--emit-updates is required'};
  }

  return {emitUpdates};
};

// ---------- runner ----------

export type RunOptions = {
  cwd?: string;
  now?: () => Date;
  pnpmRunner?: PnpmRunner;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'update-deps run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const payload = computeUpdates({cwd, pnpmRunner: options.pnpmRunner});
    const generatedAt = (options.now ?? (() => new Date()))().toISOString();
    const stamped: UpdatesPayload = {
      ...payload,
      generated_at: generatedAt,
    };

    const outPath = path.isAbsolute(parsed.emitUpdates)
      ? parsed.emitUpdates
      : path.join(cwd, parsed.emitUpdates);
    mkdirSync(path.dirname(outPath), {recursive: true});
    writeFileSync(outPath, `${JSON.stringify(stamped, null, 2)}\n`, 'utf8');

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'update_deps_run_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'update-deps run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
