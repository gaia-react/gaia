/**
 * `gaia update-deps run --emit-updates <path>` handler.
 *
 * Replicates Phases 1-3 of `.claude/skills/update-deps/SKILL.md` as a
 * deterministic shell primitive so the GAIA CI workflow can split major
 * bumps into per-group PRs before dispatching the LLM-driven flow.
 *
 * Phase 1: Discover via `pnpm outdated --json`. ESLint 9.x cap rewrites
 *          a `latest >= 10.x` to the highest available `9.x`; if already
 *          on the highest 9.x, the entry is dropped silently. A release-age
 *          cooldown then caps each target to the newest version that has
 *          cleared `minimumReleaseAge` (from `pnpm-workspace.yaml`); a target
 *          with no aged upgrade is recorded as `skipped`.
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
import {resolveGroup, resolveGroupMembers} from './groups.js';

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

const compareSegments = (
  a: readonly number[],
  b: readonly number[]
): number => {
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

/**
 * The version actually installed in `node_modules`. The package.json range
 * spec does not reveal it — a `^1.2.3` spec can resolve to any 1.x, and
 * `workspace:*` / tag / url specs carry no version at all. Returns
 * `undefined` when the package is not installed.
 */
const readInstalledVersion = (
  cwd: string,
  name: string
): string | undefined => {
  try {
    const raw = readFileSync(
      path.join(cwd, 'node_modules', name, 'package.json'),
      'utf8'
    );
    const parsed = JSON.parse(raw) as {version?: unknown};

    return typeof parsed.version === 'string' ? parsed.version : undefined;
  } catch {
    return undefined;
  }
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

const parseOutdated = (stdout: string): readonly OutdatedEntry[] => {
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

    if (typeof obj.current !== 'string' || typeof obj.latest !== 'string') {
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
  return out.toSorted((a, b) =>
    a.name < b.name ? -1
    : a.name > b.name ? 1
    : 0
  );
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

// ---------- sibling version fetch ----------

/**
 * Fetch the latest published version of a package via `pnpm view <name> version`.
 * Returns `undefined` on any failure (network error, package not found, etc.).
 */
const fetchLatestVersion = (
  name: string,
  cwd: string,
  pnpmRunner: PnpmRunner
): string | undefined => {
  const result = pnpmRunner(['view', name, 'version'], {cwd});

  if (result.status !== 0) return undefined;

  const trimmed = result.stdout.trim();

  return trimmed.length > 0 ? trimmed : undefined;
};

// ---------- release-age cooldown ----------

/**
 * Read `minimumReleaseAge` (in minutes) from the workspace's
 * `pnpm-workspace.yaml`. Returns 0 when the file is absent, unparsable, or the
 * key is missing / non-positive — in which case the cooldown is a no-op and
 * the version selection matches the pre-cooldown behaviour exactly (no extra
 * registry calls). pnpm 11 enforces this same setting on the lockfile; honour
 * it here so the dependabot flow never targets a version pnpm 11 would reject.
 */
const readMinimumReleaseAge = (cwd: string): number => {
  let raw: string;

  try {
    raw = readFileSync(path.join(cwd, 'pnpm-workspace.yaml'), 'utf8');
  } catch {
    return 0;
  }

  // The setting is a top-level integer minute count. Match it directly rather
  // than pulling a YAML parser into the bundle for one scalar — commented and
  // indented lines do not match the start-anchored key, and any inline comment
  // sits past the captured digits.
  for (const line of raw.split('\n')) {
    const match = /^minimumReleaseAge:[ \t]*(\d+)\b/u.exec(line);

    if (match) {
      const value = Number.parseInt(match[1] ?? '', 10);

      return Number.isFinite(value) && value > 0 ? value : 0;
    }
  }

  return 0;
};

/**
 * Fetch a package's `version -> ISO publish time` table via
 * `pnpm view <name> time --json`. Returns `undefined` on any failure so the
 * caller can fail closed (record the package as unresolved rather than bump to
 * a possibly-too-young version).
 */
const fetchVersionTimes = (
  name: string,
  cwd: string,
  pnpmRunner: PnpmRunner
): Readonly<Record<string, string>> | undefined => {
  const result = pnpmRunner(['view', name, 'time', '--json'], {cwd});

  if (result.status !== 0) return undefined;

  const trimmed = result.stdout.trim();

  if (trimmed.length === 0) return undefined;

  let parsed: unknown;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return undefined;
  }

  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return undefined;
  }

  const out: Record<string, string> = {};

  for (const [version, time] of Object.entries(
    parsed as Record<string, unknown>
  )) {
    if (typeof time === 'string') out[version] = time;
  }

  return out;
};

/** A semver string is a prerelease when it carries a `-` qualifier. */
const isPrerelease = (version: string): boolean => version.includes('-');

/**
 * The newest stable version that is an upgrade over `current`, at or below
 * `latest`, and published on or before `cutoffMs`. Returns `undefined` when no
 * such version exists — every available upgrade is still inside the cooldown
 * window. `time` carries `created` / `modified` pseudo-keys alongside the real
 * version keys; both are skipped.
 */
const capToAgedVersion = (params: {
  current: string;
  cutoffMs: number;
  latest: string;
  times: Readonly<Record<string, string>>;
}): string | undefined => {
  const currentSegments = parseSegments(params.current);
  const latestSegments = parseSegments(params.latest);
  let best: {raw: string; segments: readonly number[]} | undefined;

  for (const [version, isoTime] of Object.entries(params.times)) {
    if (version === 'created' || version === 'modified') continue;
    if (isPrerelease(version)) continue;

    const segments = parseSegments(version);

    if (compareSegments(segments, currentSegments) <= 0) continue;
    if (compareSegments(segments, latestSegments) > 0) continue;

    const publishedMs = Date.parse(isoTime);

    if (!Number.isFinite(publishedMs) || publishedMs > params.cutoffMs) {
      continue;
    }

    if (best === undefined || compareSegments(segments, best.segments) > 0) {
      best = {raw: version, segments};
    }
  }

  return best?.raw;
};

// ---------- compute ----------

export type ComputeOptions = {
  cwd: string;
  now?: () => Date;
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

  // `pnpm outdated` exits 0 (nothing outdated) or 1 (packages outdated) on
  // a healthy run. Any other status — including the null status of a
  // failed spawn — means pnpm itself failed; parsing its empty stdout
  // would masquerade as "everything up to date".
  const result = pnpmRunner(['outdated', '--json'], {cwd: options.cwd});

  if (result.status !== 0 && result.status !== 1) {
    throw new Error(
      `pnpm outdated failed (exit ${result.status ?? 'null'}): ${result.stderr.trim()}`
    );
  }

  const raw = parseOutdated(result.stdout);

  // Release-age cooldown. pnpm 11 re-verifies the whole lockfile against
  // `minimumReleaseAge`, so a target newer than the cooldown window would make
  // the resulting install fail. Cap each target to the newest version that has
  // already cleared the window. Disabled (no registry calls) when the setting
  // is unset, preserving the prior behaviour for adopters who do not use it.
  const now = (options.now ?? (() => new Date()))();
  const minimumReleaseAgeMinutes = readMinimumReleaseAge(options.cwd);
  const cooldownCutoffMs = now.getTime() - minimumReleaseAgeMinutes * 60_000;

  const applyCooldown = (
    name: string,
    current: string,
    latest: string
  ):
    | {kind: 'cooldown'}
    | {kind: 'ok'; latest: string}
    | {kind: 'unresolved'} => {
    if (minimumReleaseAgeMinutes <= 0) return {kind: 'ok', latest};

    // Not an upgrade (sibling already current, or a downgrade) — nothing to
    // gate; leave it so up-to-date members still flow through unchanged.
    if (compareSegments(parseSegments(latest), parseSegments(current)) <= 0) {
      return {kind: 'ok', latest};
    }

    const times = fetchVersionTimes(name, options.cwd, pnpmRunner);

    if (times === undefined) return {kind: 'unresolved'};

    const capped = capToAgedVersion({
      current,
      cutoffMs: cooldownCutoffMs,
      latest,
      times,
    });

    return capped === undefined ?
        {kind: 'cooldown'}
      : {kind: 'ok', latest: capped};
  };

  // `wanted` is the in-range floor pnpm reports; never let it exceed the
  // cooldown-capped target, or the emitted payload would be self-inconsistent.
  const clampWanted = (wanted: string, latest: string): string =>
    compareSegments(parseSegments(wanted), parseSegments(latest)) > 0 ? latest
    : wanted;

  const eslintCache: {versions?: readonly string[]} = {};
  const adjusted: Adjusted[] = [];
  const skipped: SkippedEntry[] = [];

  for (const entry of raw) {
    const decision = applyEslintCap(
      entry,
      pnpmRunner,
      options.cwd,
      eslintCache
    );

    if (decision.kind === 'drop') continue;

    const effectiveLatest =
      decision.kind === 'rewrite' ? decision.latest : entry.latest;

    const cooled = applyCooldown(entry.name, entry.current, effectiveLatest);

    if (cooled.kind !== 'ok') {
      skipped.push({
        current: entry.current,
        latest: effectiveLatest,
        name: entry.name,
        reason:
          cooled.kind === 'cooldown' ?
            'release-age-cooldown'
          : 'release-age-unresolved',
      });
      continue;
    }

    const cooledLatest = cooled.latest;
    const kind = classifyKind(entry.current, cooledLatest);

    if (kind === 'patch' && entry.current === cooledLatest) {
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
      latest: cooledLatest,
      name: entry.name,
      wanted: clampWanted(entry.wanted, cooledLatest),
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

  // Companion-group sibling expansion (Phase 2 SKILL contract).
  // For every non-singleton group with at least one outdated trigger member,
  // scan package.json for ALL members of that group and pull in any that
  // were not flagged by `pnpm outdated`. Fetch their `latest` via
  // `pnpm view <name> version`. Failures → `skipped` with
  // `reason: "registry-unresolved"`.
  const allPackageNames = Object.keys({
    ...pkg.dependencies,
    ...pkg.devDependencies,
    ...pkg.optionalDependencies,
    ...pkg.peerDependencies,
  });

  for (const [group, members] of byGroup) {
    if (group.startsWith('singleton:')) continue;

    const alreadyInGroup = new Set(members.map((m) => m.name));
    const allGroupMembers = resolveGroupMembers(group, allPackageNames);

    for (const siblingName of allGroupMembers) {
      if (alreadyInGroup.has(siblingName)) continue;

      // Sibling is in package.json but not flagged by pnpm outdated.
      const spec = lookupSpec(pkg, siblingName);

      // Prefer the version actually installed in node_modules; the
      // package.json spec (`^x`, `workspace:*`, a tag, …) is not a usable
      // version. Fall back to the spec floor only when node_modules has no
      // entry (e.g. dependencies not installed).
      const current =
        readInstalledVersion(options.cwd, siblingName) ??
        (spec !== undefined ? stripRange(spec) : '');
      const latest = fetchLatestVersion(siblingName, options.cwd, pnpmRunner);

      if (latest === undefined) {
        // Registry call failed — omit from emit, record in skipped.
        skipped.push({
          current,
          latest: '',
          name: siblingName,
          reason: 'registry-unresolved',
        });
        continue;
      }

      const cooled = applyCooldown(siblingName, current, latest);

      if (cooled.kind !== 'ok') {
        skipped.push({
          current,
          latest,
          name: siblingName,
          reason:
            cooled.kind === 'cooldown' ?
              'release-age-cooldown'
            : 'release-age-unresolved',
        });
        continue;
      }

      const cooledLatest = cooled.latest;

      // If current === latest, kind is "patch" (no-op default per spec).
      const kind: Kind =
        current !== '' && current !== cooledLatest ?
          classifyKind(current, cooledLatest)
        : 'patch';

      members.push({
        current,
        group,
        is_pinned: isPinnedSpec(spec),
        kind,
        latest: cooledLatest,
        name: siblingName,
        wanted: cooledLatest,
      });
    }
  }

  const waveA: WaveAEntry[] = [];
  const waveB: WaveBGroup[] = [];

  for (const [group, members] of byGroup) {
    const hasMajor = members.some((member) => member.kind === 'major');

    if (hasMajor) {
      const sorted = members.toSorted((a, b) =>
        a.name < b.name ? -1
        : a.name > b.name ? 1
        : 0
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
  waveA.sort((a, b) =>
    a.name < b.name ? -1
    : a.name > b.name ? 1
    : 0
  );
  waveB.sort((a, b) =>
    a.group < b.group ? -1
    : a.group > b.group ? 1
    : 0
  );

  return {
    generated_at: now.toISOString(),
    schema_version: 1,
    skipped,
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
    const payload = computeUpdates({
      cwd,
      now: options.now,
      pnpmRunner: options.pnpmRunner,
    });
    const stamped: UpdatesPayload = payload;

    const outPath =
      path.isAbsolute(parsed.emitUpdates) ?
        parsed.emitUpdates
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
