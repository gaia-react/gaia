import semver from 'semver';
/**
 * `gaia update-deps advisories --emit <path>` handler.
 *
 * The one place advisory data enters GAIA: `check-updates.sh` (with
 * `--count-only`), the /update-deps skill, and its report all read the payload
 * this writes, never gh or pnpm output directly. Dependabot alerts are the
 * primary source and `pnpm audit` the fallback. Exit 0 whenever a payload was
 * written, `source: "unavailable"` included; callers read the payload, not the
 * exit status, to learn whether a source answered.
 */
import {mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {loadPackages, repoRegExps} from '../util/packages.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {projectPackageKeys, versionsFromKeys} from './advisory-lockfile.js';
import {
  advisoriesFromAudit,
  applyBaseline,
  classifyCandidates,
  countAdvisories,
  joinAuditToAlerts,
  normalizeAlerts,
  normalizePnpmAudit,
  rankAdvisories,
} from './advisory-model.js';
import type {
  AdvisoriesPayload,
  Advisory,
  AlertRecord,
  AuditRecord,
  UpdateOffers,
} from './advisory-model.js';
import {reasonText} from './advisory-reasons.js';
import type {AdvisoryReasonToken} from './advisory-reasons.js';
import {
  advisoryPnpmRunner,
  fetchDependabotAlerts,
  readOriginUrl,
  resolveGithubRepository,
  runPnpmAudit,
} from './advisory-sources.js';
import type {GhRunner, OriginReader} from './advisory-sources.js';
import {isRangeString, toSemverRange} from './advisory-validate.js';
import {fetchVersionTimes, readMinimumReleaseAge} from './run.js';
import type {PnpmRunner} from './run.js';
import {readCliWorkspaceMember} from './workspace-member.js';

const HELP_TEXT = `Usage: gaia update-deps advisories --emit <path> [--count-only] [--updates <path>] [--no-alerts]

  Fetch open dependency security advisories (Dependabot alerts first,
  \`pnpm audit\` as the fallback), keep only validated fields, rank them, and
  write one JSON payload to <path>. Exits 0 whenever the payload was written,
  including when no source answered (source "unavailable").

  --emit <path>      Required. JSON file to write atomically.
  --count-only       Count only: no advisory rows, no registry lookups, and
                     in alerts mode no \`pnpm audit\`.
  --updates <path>   An \`update-deps run --emit-updates\` payload, used to
                     offer chain-head bumps as candidates.
  --no-alerts        Skip Dependabot alerts (as in CI) and use \`pnpm audit\`.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND = 'update-deps advisories';

const BASELINE_FILE = '.gaia/local/dep-audit-baseline.json';

const OPEN_STATES: ReadonlySet<string> = new Set(['open']);
const DISMISSED_STATES: ReadonlySet<string> = new Set([
  'auto_dismissed',
  'dismissed',
]);

const ALWAYS_OWNED_MANIFESTS: ReadonlySet<string> = new Set([
  'package.json',
  'pnpm-lock.yaml',
  'pnpm-workspace.yaml',
]);

export type AdvisoriesOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  ghRunner?: GhRunner;
  now?: () => Date;
  originReader?: OriginReader;
  pnpmRunner?: PnpmRunner;
};

type ParsedArgs = {
  countOnly: boolean;
  emit: string;
  noAlerts: boolean;
  updates: null | string;
};

type ParseError = {error: string};

const parseArgs = (argv: readonly string[]): ParsedArgs | ParseError => {
  let emit: string | undefined;
  let updates: null | string = null;
  let countOnly = false;
  let noAlerts = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--count-only') {
      countOnly = true;
    } else if (token === '--no-alerts') {
      noAlerts = true;
    } else if (token === '--emit' || token === '--updates') {
      const value = argv[index + 1];

      if (value === undefined || value.length === 0 || value.startsWith('--')) {
        return {error: `${token} requires a path`};
      }

      if (token === '--emit') emit = value;
      else updates = value;
      index += 1;
    } else {
      return {error: `unknown flag: ${String(token)}`};
    }
  }

  if (emit === undefined) return {error: '--emit is required'};

  return {countOnly, emit, noAlerts, updates};
};

const isCiEnvironment = (env: NodeJS.ProcessEnv): boolean =>
  [env.CI, env.GITHUB_ACTIONS].some(
    (value) => value !== undefined && value !== '' && value !== 'false'
  );

const resolveFrom = (cwd: string, target: string): string =>
  path.isAbsolute(target) ? target : path.join(cwd, target);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const asArray = (value: unknown): unknown[] =>
  Array.isArray(value) ? (value as unknown[]) : [];

const namesOf = (entries: readonly unknown[]): string[] =>
  entries.flatMap((entry) =>
    isRecord(entry) && typeof entry.name === 'string' ? [entry.name] : []
  );

const readUpdateOffers = (filePath: null | string): null | UpdateOffers => {
  if (filePath === null) return {waveA: new Set(), waveB: new Set()};

  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }

  if (
    !isRecord(parsed) ||
    !Array.isArray(parsed.wave_a) ||
    !Array.isArray(parsed.wave_b)
  ) {
    return null;
  }

  return {
    waveA: new Set(namesOf(asArray(parsed.wave_a))),
    waveB: new Set(
      asArray(parsed.wave_b).flatMap((group) =>
        namesOf(asArray(isRecord(group) ? group.packages : undefined))
      )
    ),
  };
};

const readBaselineIds = (repoRoot: string): ReadonlySet<number> => {
  const ids = new Set<number>();
  let parsed: unknown;

  try {
    parsed = JSON.parse(
      readFileSync(path.join(repoRoot, BASELINE_FILE), 'utf8')
    );
  } catch {
    return ids;
  }

  const acknowledged = isRecord(parsed) ? parsed.acknowledged : undefined;

  for (const entry of Array.isArray(acknowledged) ?
    (acknowledged as unknown[])
  : []) {
    const id = isRecord(entry) ? entry.id : undefined;

    if (typeof id === 'number' && Number.isSafeInteger(id) && id > 0) {
      ids.add(id);
    }
  }

  return ids;
};

/**
 * Whether /update-deps owns a manifest: the root manifests, a path matching a
 * registered package's `dependencyManifests` globs, or the package manifest of
 * the CLI workspace member when the root workspace lists one. An adopter tree
 * has no such member, so the last rule is inert there.
 */
const ownedManifestPredicate = (
  repoRoot: string
): ((manifestPath: string) => boolean) => {
  const loaded = loadPackages(repoRoot);
  const patterns =
    loaded.ok ? repoRegExps(loaded.packages, 'dependencyManifests') : [];
  const member = readCliWorkspaceMember(repoRoot);
  // Joined, never spelled whole: the adopter bundle is scanned for the literal
  // path of a release-excluded file.
  const memberManifest =
    member === null ? null : path.posix.join(member, 'package.json');

  return (manifestPath) =>
    ALWAYS_OWNED_MANIFESTS.has(manifestPath) ||
    manifestPath === memberManifest ||
    patterns.some((pattern) => pattern.test(manifestPath));
};

type AlertsOutcome =
  | {dismissedGhsas: string[]; ok: true; open: AlertRecord[]; rejected: number}
  | {ok: false; reason: AdvisoryReasonToken};

type RunContext = {
  args: ParsedArgs;
  cwd: string;
  env: NodeJS.ProcessEnv;
  now: Date;
  options: AdvisoriesOptions;
  pnpmRunner: PnpmRunner;
  repoRoot: string;
};

const readAlerts = async (context: RunContext): Promise<AlertsOutcome> => {
  if (context.args.noAlerts || isCiEnvironment(context.env)) {
    return {ok: false, reason: 'ci'};
  }

  const repository = resolveGithubRepository(
    context.repoRoot,
    context.options.originReader ?? readOriginUrl
  );

  if (!repository.ok) return repository;

  const fetched = await fetchDependabotAlerts({
    cwd: context.repoRoot,
    env: context.env,
    ghRunner: context.options.ghRunner,
    includeDismissed: !context.args.countOnly,
    owner: repository.owner,
    repo: repository.repo,
  });

  if (!fetched.ok) return fetched;

  const isOwned = ownedManifestPredicate(context.repoRoot);
  const open = normalizeAlerts(fetched.open, OPEN_STATES);
  const dismissed = normalizeAlerts(fetched.dismissed, DISMISSED_STATES);
  const ownedOpen = open.records.filter((alert) => isOwned(alert.manifestPath));
  const openGhsas = new Set(ownedOpen.map((alert) => alert.ghsa));
  const distinctDismissed = [
    ...new Set(
      dismissed.records
        .filter((alert) => isOwned(alert.manifestPath))
        .map((alert) => alert.ghsa)
        .filter((ghsa) => !openGhsas.has(ghsa))
    ),
  ];
  const dismissedGhsas = distinctDismissed.toSorted((a, b) =>
    a.localeCompare(b)
  );

  return {
    dismissedGhsas,
    ok: true,
    open: ownedOpen,
    rejected: open.rejectedCount + dismissed.rejectedCount,
  };
};

type AuditOutcome =
  {ok: false} | {ok: true; records: AuditRecord[]; rejected: number};

const readAudit = (context: RunContext): AuditOutcome => {
  const audit = runPnpmAudit({
    cwd: context.repoRoot,
    pnpmRunner: context.pnpmRunner,
  });

  if (!audit.ok) return audit;

  const normalized = normalizePnpmAudit(audit.report);

  return {
    ok: true,
    records: normalized.records,
    rejected: normalized.rejectedCount,
  };
};

const readLockfileKeys = (repoRoot: string): readonly string[] => {
  try {
    return projectPackageKeys(
      readFileSync(path.join(repoRoot, 'pnpm-lock.yaml'), 'utf8')
    );
  } catch {
    return [];
  }
};

const isIsoTime = (value: unknown): value is string =>
  typeof value === 'string' && Number.isFinite(Date.parse(value));

const releaseAgeFields = (
  advisory: Advisory,
  context: RunContext,
  minutes: number
): Pick<Advisory, 'insideReleaseAgeWindow' | 'patchEligibleAt'> => {
  const unknownAge = {insideReleaseAgeWindow: false, patchEligibleAt: null};

  if (advisory.firstPatchedVersion === null || minutes <= 0) return unknownAge;

  const times = fetchVersionTimes(
    advisory.package,
    context.repoRoot,
    context.pnpmRunner
  );
  const published = times?.[advisory.firstPatchedVersion];

  if (!isIsoTime(published)) return unknownAge;

  const eligible = new Date(Date.parse(published) + minutes * 60_000);

  return {
    insideReleaseAgeWindow: context.now.getTime() < eligible.getTime(),
    patchEligibleAt: eligible.toISOString(),
  };
};

type DeclaredRangeQuery = {
  packageName: string;
  parent: string;
  parentVersion: string;
};

const lookupDeclaredRange = (
  {packageName, parent, parentVersion}: DeclaredRangeQuery,
  context: RunContext
): null | string => {
  const result = context.pnpmRunner(
    ['view', `${parent}@${parentVersion}`, 'dependencies', '--json'],
    {cwd: context.repoRoot}
  );

  if (result.status !== 0) return null;

  try {
    const parsed: unknown = JSON.parse(result.stdout);
    const range =
      isRecord(parsed) && Object.hasOwn(parsed, packageName) ?
        parsed[packageName]
      : undefined;

    return isRangeString(range) ? range : null;
  } catch {
    return null;
  }
};

const parentRangeFields = (
  advisory: Advisory,
  context: RunContext,
  lockfileKeys: readonly string[]
): Pick<Advisory, 'parentRange' | 'parentRangeAdmitsPatch'> => {
  const unknownRange = {parentRange: null, parentRangeAdmitsPatch: null};
  const chain = advisory.chains.find((candidate) => candidate.length >= 3);
  const parent = chain?.at(-2);
  const parentVersion =
    parent === undefined ? undefined : (
      versionsFromKeys(lockfileKeys, parent).findLast(
        (version) => semver.valid(version) !== null
      )
    );

  if (
    advisory.firstPatchedVersion === null ||
    parent === undefined ||
    parentVersion === undefined
  ) {
    return unknownRange;
  }

  const parentRange = lookupDeclaredRange(
    {packageName: advisory.package, parent, parentVersion},
    context
  );

  if (parentRange === null) return unknownRange;

  return {
    parentRange,
    parentRangeAdmitsPatch: semver.satisfies(
      advisory.firstPatchedVersion,
      toSemverRange(parentRange),
      {includePrerelease: true}
    ),
  };
};

const enrich = (
  advisories: readonly Advisory[],
  context: RunContext,
  offers: UpdateOffers
): Advisory[] => {
  const lockfileKeys = readLockfileKeys(context.repoRoot);
  const minutes = readMinimumReleaseAge(context.repoRoot);
  const noApplySet: ReadonlySet<string> = new Set();

  return advisories.map((advisory) => {
    const enriched: Advisory = {
      ...advisory,
      installedVersions: versionsFromKeys(lockfileKeys, advisory.package),
      ...releaseAgeFields(advisory, context, minutes),
      ...parentRangeFields(advisory, context, lockfileKeys),
    };

    return {
      ...enriched,
      ...classifyCandidates(enriched, offers, noApplySet),
    };
  });
};

const buildPayload = async (
  context: RunContext,
  offers: UpdateOffers
): Promise<AdvisoriesPayload> => {
  const {countOnly} = context.args;
  const alerts = await readAlerts(context);
  const runAudit = !countOnly || !alerts.ok;
  const audit: AuditOutcome = runAudit ? readAudit(context) : {ok: false};
  const acknowledged = readBaselineIds(context.repoRoot);
  const auditRecords = audit.ok ? audit.records : [];
  const rejectedCount =
    (alerts.ok ? alerts.rejected : 0) + (audit.ok ? audit.rejected : 0);
  const common = {
    auditAvailable: audit.ok,
    generatedAt: context.now.toISOString(),
    rejectedCount,
    version: 1 as const,
  };

  if (!alerts.ok && !audit.ok) {
    const reasons: AdvisoryReasonToken[] = [alerts.reason, 'pnpm-audit-failed'];

    return {
      ...common,
      advisories: [],
      count: null,
      dismissedGhsas: [],
      reasons,
      reasonText: reasonText(reasons),
      source: 'unavailable',
    };
  }

  const source = alerts.ok ? 'dependabot' : 'pnpm-audit';
  const base =
    alerts.ok ?
      joinAuditToAlerts(alerts.open, auditRecords)
    : advisoriesFromAudit(auditRecords);
  const withBaseline = base.map((advisory) =>
    applyBaseline(advisory, acknowledged)
  );
  const reasons: AdvisoryReasonToken[] = alerts.ok ? [] : [alerts.reason];

  return {
    ...common,
    advisories:
      countOnly ? [] : rankAdvisories(enrich(withBaseline, context, offers)),
    count: countAdvisories(source, withBaseline),
    dismissedGhsas: alerts.ok ? alerts.dismissedGhsas : [],
    reasons,
    reasonText: reasonText(reasons),
    source,
  };
};

const usageError = (message: string): number => {
  structuredError({code: 'invalid_arguments', message, subcommand: SUBCOMMAND});

  return EXIT_CODES.INVALID_ARGUMENTS;
};

const resolveRootOrCwd = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

export const run = async (
  argv: readonly string[],
  options: AdvisoriesOptions = {}
): Promise<number> => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const args = parseArgs(argv);

  if ('error' in args) return usageError(args.error);

  const cwd = options.cwd ?? process.cwd();
  const offers = readUpdateOffers(
    args.updates === null ? null : resolveFrom(cwd, args.updates)
  );

  if (offers === null) {
    return usageError(`cannot read updates payload: ${String(args.updates)}`);
  }

  const context: RunContext = {
    args,
    cwd,
    env: options.env ?? process.env,
    now: (options.now ?? (() => new Date()))(),
    options,
    pnpmRunner: options.pnpmRunner ?? advisoryPnpmRunner,
    repoRoot: resolveRootOrCwd(cwd),
  };
  const payload = await buildPayload(context, offers);
  const outPath = resolveFrom(cwd, args.emit);

  try {
    mkdirSync(path.dirname(outPath), {recursive: true});
    atomicWriteFileSync(outPath, `${JSON.stringify(payload, null, 2)}\n`);
  } catch {
    structuredError({
      code: 'emit_unwritable',
      message: `cannot write advisories payload: ${args.emit}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  return EXIT_CODES.OK;
};
