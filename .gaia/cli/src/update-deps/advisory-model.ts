/**
 * The advisories payload model: field selection and validation of raw
 * Dependabot and `pnpm audit` records, the join between them, the baseline,
 * the candidate classifier, ranking, and the count.
 *
 * Field selection is an allowlist: a record is read only through the fields
 * named here, so summary, description, references, and every other free-text
 * field never reach a value that can be emitted. Each kept value is validated;
 * a record with one failing value is dropped whole and counted as rejected.
 */
import semver from 'semver';
import type {AdvisoryReasonToken} from './advisory-reasons.js';
import {
  isGhsaId,
  isManifestPath,
  isNpmPackageName,
  isPositiveInteger,
  isRangeString,
  isSemverVersion,
  normalizeRelationship,
  normalizeScope,
  normalizeSeverity,
  toSemverRange,
} from './advisory-validate.js';
import type {
  AdvisoryRelationship,
  AdvisoryScope,
  AdvisorySeverity,
} from './advisory-validate.js';

/** The JSON payload `gaia update-deps advisories --emit` writes. */
export type AdvisoriesPayload = {
  advisories: Advisory[];
  auditAvailable: boolean;
  count: null | number;
  dismissedGhsas: string[];
  generatedAt: string;
  reasons: AdvisoryReasonToken[];
  reasonText: string;
  rejectedCount: number;
  source: AdvisorySource;
  version: 1;
};

/** One advisory in the payload, keyed by GHSA id (or `pnpm:<id>`). */
export type Advisory = {
  alerts: AdvisoryAlertReference[];
  baselineAcknowledged: boolean;
  baselineIds: number[];
  blockedReason: BlockedReason | null;
  candidates: AdvisoryCandidate[];
  chains: string[][];
  epssPercentage: null | number;
  firstPatchedVersion: null | string;
  ghsa: null | string;
  insideReleaseAgeWindow: boolean;
  installedVersions: string[];
  key: string;
  package: string;
  parentRange: null | string;
  parentRangeAdmitsPatch: boolean | null;
  patchEligibleAt: null | string;
  pathCount: number;
  pnpmIds: number[];
  relationship: AdvisoryRelationship;
  scope: AdvisoryScope;
  severity: AdvisorySeverity;
  vulnerableRange: null | string;
};

export type AdvisoryAlertReference = {manifestPath: string; number: number};

export type AdvisoryCandidate =
  | 'chain-head-in-run'
  | 'chain-head-major'
  | 'chain-head-minor'
  | 'in-range-refresh'
  | 'override';

export type AdvisorySource = 'dependabot' | 'pnpm-audit' | 'unavailable';

/** A validated Dependabot alert, reduced to the allowlisted fields. */
export type AlertRecord = {
  epssPercentage: null | number;
  firstPatchedVersion: null | string;
  ghsa: string;
  manifestPath: string;
  number: number;
  package: string;
  relationship: AdvisoryRelationship;
  scope: AdvisoryScope;
  severity: AdvisorySeverity;
  vulnerableRange: null | string;
};

export type AuditFinding = {paths: string[]; version: string};

/** A validated `pnpm audit` advisory, reduced to the allowlisted fields. */
export type AuditRecord = {
  findings: AuditFinding[];
  firstPatchedVersion: null | string;
  ghsa: null | string;
  id: number;
  package: string;
  severity: AdvisorySeverity;
  vulnerableRange: null | string;
};

export type BlockedReason = 'no-patch' | 'release-age';

export type NormalizeResult<TRecord> = {
  records: TRecord[];
  rejectedCount: number;
};

/** Package names a `--updates` payload offers, by wave. */
export type UpdateOffers = {
  waveA: ReadonlySet<string>;
  waveB: ReadonlySet<string>;
};

const MAXIMUM_CHAINS = 5;

/** A field read: the validated value, or a rejection of the whole record. */
type FieldRead<TValue> = {ok: false} | {ok: true; value: TValue};

const REJECTED: {ok: false} = {ok: false};

const accept = <TValue>(value: TValue): FieldRead<TValue> => ({
  ok: true,
  value,
});

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const field = (value: unknown, key: string): unknown =>
  isRecord(value) && Object.hasOwn(value, key) ? value[key] : undefined;

const compareStrings = (a: string, b: string): number => {
  if (a < b) return -1;

  return a > b ? 1 : 0;
};

// ---------- field readers ----------

/** A nullable range: null or absent is null, anything else must validate. */
const readOptionalRange = (value: unknown): FieldRead<null | string> => {
  if (value === null || value === undefined) return accept(null);

  return isRangeString(value) ? accept(value) : REJECTED;
};

const readAlertFirstPatched = (value: unknown): FieldRead<null | string> => {
  if (value === null || value === undefined) return accept(null);
  if (!isRecord(value)) return REJECTED;

  const identifier = field(value, 'identifier');

  if (identifier === null || identifier === undefined) return accept(null);

  return isSemverVersion(identifier) ? accept(identifier) : REJECTED;
};

const readEpss = (advisory: unknown): null | number => {
  const epss = field(advisory, 'epss');
  const entry = Array.isArray(epss) ? (epss as unknown[])[0] : epss;
  const percentage = field(entry, 'percentage');

  return (
      typeof percentage === 'number' &&
        Number.isFinite(percentage) &&
        percentage >= 0 &&
        percentage <= 1
    ) ?
      percentage
    : null;
};

/** The first patched version of a pnpm `patched_versions` range. */
const readAuditFirstPatched = (value: unknown): FieldRead<null | string> => {
  const range = readOptionalRange(value);

  if (!range.ok || range.value === null) return range;

  return accept(semver.minVersion(toSemverRange(range.value))?.version ?? null);
};

// ---------- alerts ----------

const normalizeAlert = (raw: unknown): AlertRecord | null => {
  const dependency = field(raw, 'dependency');
  const advisory = field(raw, 'security_advisory');
  const vulnerability = field(raw, 'security_vulnerability');
  const number = field(raw, 'number');
  const packageName = field(field(dependency, 'package'), 'name');
  const manifestPath = field(dependency, 'manifest_path');
  const ghsa = field(advisory, 'ghsa_id');
  const severity = normalizeSeverity(
    field(advisory, 'severity') ?? field(vulnerability, 'severity')
  );
  const scope = normalizeScope(field(dependency, 'scope'));
  const relationship = normalizeRelationship(field(dependency, 'relationship'));
  const vulnerableRange = readOptionalRange(
    field(vulnerability, 'vulnerable_version_range')
  );
  const firstPatchedVersion = readAlertFirstPatched(
    field(vulnerability, 'first_patched_version')
  );

  if (
    !isPositiveInteger(number) ||
    !isNpmPackageName(packageName) ||
    !isManifestPath(manifestPath) ||
    !isGhsaId(ghsa) ||
    severity === null ||
    scope === null ||
    relationship === null ||
    !vulnerableRange.ok ||
    !firstPatchedVersion.ok
  ) {
    return null;
  }

  return {
    epssPercentage: readEpss(advisory),
    firstPatchedVersion: firstPatchedVersion.value,
    ghsa,
    manifestPath,
    number,
    package: packageName,
    relationship,
    scope,
    severity,
    vulnerableRange: vulnerableRange.value,
  };
};

const isNpmAlertInState = (
  entry: unknown,
  states: ReadonlySet<string>
): boolean => {
  const state = field(entry, 'state');
  const ecosystem = field(
    field(field(entry, 'dependency'), 'package'),
    'ecosystem'
  );

  return typeof state === 'string' && states.has(state) && ecosystem === 'npm';
};

/**
 * Validated alerts whose `state` is one of `states` and whose ecosystem is
 * npm. A record in another state or ecosystem is skipped, not rejected: the
 * query already asked for these, so a stray one is noise, not hostile input.
 */
export const normalizeAlerts = (
  raw: readonly unknown[],
  states: ReadonlySet<string>
): NormalizeResult<AlertRecord> => {
  const records: AlertRecord[] = [];
  let rejectedCount = 0;

  for (const entry of raw.filter((candidate) =>
    isNpmAlertInState(candidate, states)
  )) {
    const record = normalizeAlert(entry);

    if (record === null) rejectedCount += 1;
    else records.push(record);
  }

  return {records, rejectedCount};
};

// ---------- pnpm audit ----------

const isChainSegment = (segment: string, index: number): boolean =>
  index === 0 ?
    segment === '.' || isManifestPath(segment)
  : isNpmPackageName(segment);

/** Split a pnpm audit path on `>`; segment 0 is the importer, verbatim. */
export const normalizeChain = (auditPath: string): string[] =>
  auditPath.split('>');

const isValidAuditPath = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.length <= 4096 &&
  normalizeChain(value).every((segment, index) =>
    isChainSegment(segment, index)
  ) &&
  normalizeChain(value).length >= 2;

const readFindings = (value: unknown): FieldRead<AuditFinding[]> => {
  if (value === null || value === undefined) return accept([]);
  if (!Array.isArray(value)) return REJECTED;

  const findings: AuditFinding[] = [];

  for (const entry of value as unknown[]) {
    const version = field(entry, 'version');
    const paths = field(entry, 'paths') ?? [];

    if (!isSemverVersion(version) || !Array.isArray(paths)) return REJECTED;

    const typedPaths = paths as unknown[];

    if (!typedPaths.every((candidate) => isValidAuditPath(candidate))) {
      return REJECTED;
    }

    findings.push({paths: typedPaths, version});
  }

  return accept(findings);
};

const normalizeAuditAdvisory = (raw: unknown): AuditRecord | null => {
  const id = field(raw, 'id');
  const ghsaValue = field(raw, 'github_advisory_id');
  const packageName = field(raw, 'module_name');
  const severity = normalizeSeverity(field(raw, 'severity'));
  const vulnerableRange = readOptionalRange(field(raw, 'vulnerable_versions'));
  const firstPatchedVersion = readAuditFirstPatched(
    field(raw, 'patched_versions')
  );
  const findings = readFindings(field(raw, 'findings'));
  const ghsaValid =
    ghsaValue === null || ghsaValue === undefined || isGhsaId(ghsaValue);

  if (
    !isPositiveInteger(id) ||
    !ghsaValid ||
    !isNpmPackageName(packageName) ||
    severity === null ||
    !vulnerableRange.ok ||
    !firstPatchedVersion.ok ||
    !findings.ok
  ) {
    return null;
  }

  return {
    findings: findings.value,
    firstPatchedVersion: firstPatchedVersion.value,
    ghsa: isGhsaId(ghsaValue) ? ghsaValue : null,
    id,
    package: packageName,
    severity,
    vulnerableRange: vulnerableRange.value,
  };
};

/** Validated advisories from a parsed `pnpm audit --json` report. */
export const normalizePnpmAudit = (
  report: unknown
): NormalizeResult<AuditRecord> => {
  const advisories = field(report, 'advisories');
  const records: AuditRecord[] = [];
  let rejectedCount = 0;

  if (!isRecord(advisories)) return {records, rejectedCount};

  for (const entry of Object.values(advisories)) {
    const record = normalizeAuditAdvisory(entry);

    if (record === null) rejectedCount += 1;
    else records.push(record);
  }

  return {records, rejectedCount};
};

// ---------- join ----------

const SEVERITY_ORDER: readonly AdvisorySeverity[] = [
  'critical',
  'high',
  'medium',
  'low',
];

const severityRank = (severity: AdvisorySeverity): number =>
  SEVERITY_ORDER.indexOf(severity);

const highestSeverity = (
  severities: readonly AdvisorySeverity[]
): AdvisorySeverity =>
  severities.reduce<AdvisorySeverity>(
    (best, next) => (severityRank(next) < severityRank(best) ? next : best),
    'low'
  );

const chainsOf = (
  records: readonly AuditRecord[]
): {chains: string[][]; pathCount: number} => {
  const seen = new Set<string>();
  const chains: string[][] = [];

  for (const record of records) {
    for (const finding of record.findings) {
      for (const auditPath of finding.paths) {
        if (!seen.has(auditPath)) {
          seen.add(auditPath);
          chains.push(normalizeChain(auditPath));
        }
      }
    }
  }

  return {chains: chains.slice(0, MAXIMUM_CHAINS), pathCount: seen.size};
};

const baseAdvisory = (
  key: string,
  packageName: string,
  severity: AdvisorySeverity
): Advisory => ({
  alerts: [],
  baselineAcknowledged: false,
  baselineIds: [],
  blockedReason: null,
  candidates: [],
  chains: [],
  epssPercentage: null,
  firstPatchedVersion: null,
  ghsa: null,
  insideReleaseAgeWindow: false,
  installedVersions: [],
  key,
  package: packageName,
  parentRange: null,
  parentRangeAdmitsPatch: null,
  patchEligibleAt: null,
  pathCount: 0,
  pnpmIds: [],
  relationship: 'n/a',
  scope: 'n/a',
  severity,
  vulnerableRange: null,
});

const groupBy = <TRecord>(
  records: readonly TRecord[],
  keyOf: (record: TRecord) => string
): Map<string, TRecord[]> => {
  const groups = new Map<string, TRecord[]>();

  for (const record of records) {
    const key = keyOf(record);
    const list = groups.get(key);

    if (list === undefined) groups.set(key, [record]);
    else list.push(record);
  }

  return groups;
};

const firstNonNull = <TValue>(
  values: readonly (null | TValue)[]
): null | TValue => values.find((value) => value !== null) ?? null;

/**
 * One advisory per GHSA and package among the alerts, enriched with pnpm ids
 * and chains from the audit records carrying the same GHSA and package. A GHSA
 * spanning several packages yields one advisory each, all sharing the GHSA as
 * their key, so each package gets its own landed check and alert list.
 */
export const joinAuditToAlerts = (
  alerts: readonly AlertRecord[],
  audit: readonly AuditRecord[]
): Advisory[] =>
  [
    ...groupBy(
      alerts,
      (alert) => `${alert.ghsa}\u0000${alert.package}`
    ).values(),
  ].map((group) => {
    const [first] = group as [AlertRecord, ...AlertRecord[]];
    const {ghsa, package: packageName, relationship, scope} = first;
    const joined = audit.filter(
      (record) => record.ghsa === ghsa && record.package === packageName
    );
    const {chains, pathCount} = chainsOf(joined);

    return {
      ...baseAdvisory(
        ghsa,
        packageName,
        highestSeverity(group.map((alert) => alert.severity))
      ),
      alerts: group
        .map((alert) => ({
          manifestPath: alert.manifestPath,
          number: alert.number,
        }))
        .toSorted((a, b) => a.number - b.number),
      chains,
      epssPercentage: firstNonNull(group.map((alert) => alert.epssPercentage)),
      firstPatchedVersion: firstNonNull(
        group.map((alert) => alert.firstPatchedVersion)
      ),
      ghsa,
      pathCount,
      pnpmIds: joined.map((record) => record.id).toSorted((a, b) => a - b),
      relationship,
      scope:
        group.some((alert) => alert.scope === 'runtime') ? 'runtime' : scope,
      vulnerableRange: firstNonNull(
        group.map((alert) => alert.vulnerableRange)
      ),
    };
  });

const relationshipFromChain = (
  chain: readonly string[] | undefined
): AdvisoryRelationship => {
  if (chain === undefined) return 'n/a';

  return chain.length === 2 ? 'direct' : 'transitive';
};

const auditKeyOf = (record: AuditRecord): string =>
  record.ghsa ?? `pnpm:${String(record.id)}`;

/**
 * One advisory per key and package among the audit records (the key is the
 * GHSA id, or `pnpm:<id>` for a record with none), for the fallback source.
 */
export const advisoriesFromAudit = (
  audit: readonly AuditRecord[]
): Advisory[] =>
  [
    ...groupBy(
      audit,
      (record) => `${auditKeyOf(record)}\u0000${record.package}`
    ).values(),
  ].map((group) => {
    const [first] = group as [AuditRecord, ...AuditRecord[]];
    const key = auditKeyOf(first);
    const {chains, pathCount} = chainsOf(group);

    return {
      ...baseAdvisory(
        key,
        first.package,
        highestSeverity(group.map((record) => record.severity))
      ),
      chains,
      firstPatchedVersion: firstNonNull(
        group.map((record) => record.firstPatchedVersion)
      ),
      ghsa: first.ghsa,
      pathCount,
      pnpmIds: group.map((record) => record.id).toSorted((a, b) => a - b),
      relationship: relationshipFromChain(chains[0]),
      vulnerableRange: firstNonNull(
        group.map((record) => record.vulnerableRange)
      ),
    };
  });

// ---------- baseline ----------

/**
 * Baseline ids that map to this advisory through its pnpm ids. An id is never
 * matched by module name: an id that maps to no pnpm record matches nothing.
 */
export const applyBaseline = (
  advisory: Advisory,
  acknowledged: ReadonlySet<number>
): Advisory => {
  const baselineIds = advisory.pnpmIds.filter((id) => acknowledged.has(id));

  return {
    ...advisory,
    baselineAcknowledged:
      advisory.pnpmIds.length > 0 &&
      baselineIds.length === advisory.pnpmIds.length,
    baselineIds,
  };
};

// ---------- classifier ----------

/**
 * Candidate resolutions for an advisory, in the order /update-deps tries them.
 * `applySet` is the set of package names the human's decision applies; the
 * advisories verb passes an empty set because it runs before that decision,
 * and the skill re-applies this rule once the decision is known.
 */
export const classifyCandidates = (
  advisory: Advisory,
  updates: UpdateOffers,
  applySet: ReadonlySet<string>
): Pick<Advisory, 'blockedReason' | 'candidates'> => {
  if (advisory.firstPatchedVersion === null) {
    return {blockedReason: 'no-patch', candidates: []};
  }

  if (advisory.insideReleaseAgeWindow) {
    return {blockedReason: 'release-age', candidates: []};
  }

  const head = advisory.chains[0]?.[1];
  const candidates: AdvisoryCandidate[] = [];

  if (advisory.parentRangeAdmitsPatch !== false) {
    candidates.push('in-range-refresh');
  }

  const headInRun = head !== undefined && applySet.has(head);
  const headMinor = !headInRun && head !== undefined && updates.waveA.has(head);

  if (headInRun) candidates.push('chain-head-in-run');
  else if (headMinor) candidates.push('chain-head-minor');

  candidates.push('override');

  if (
    !headInRun &&
    !headMinor &&
    head !== undefined &&
    updates.waveB.has(head)
  ) {
    candidates.push('chain-head-major');
  }

  return {blockedReason: null, candidates};
};

// ---------- ranking and count ----------

const compareEpss = (a: null | number, b: null | number): number => {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;

  return b - a;
};

/** Severity, then EPSS descending with null last, then key ascending. */
export const rankAdvisories = (advisories: readonly Advisory[]): Advisory[] =>
  advisories.toSorted(
    (a, b) =>
      severityRank(a.severity) - severityRank(b.severity) ||
      compareEpss(a.epssPercentage, b.epssPercentage) ||
      compareStrings(a.key, b.key) ||
      compareStrings(a.package, b.package)
  );

/**
 * The payload count: distinct GHSA ids on the alerts source (the baseline is
 * ignored there), or distinct keys minus baseline-acknowledged ones on the
 * `pnpm audit` source. A GHSA spanning several packages counts once.
 */
export const countAdvisories = (
  source: Exclude<AdvisorySource, 'unavailable'>,
  advisories: readonly Advisory[]
): number => {
  const counted =
    source === 'dependabot' ? advisories : (
      advisories.filter((advisory) => !advisory.baselineAcknowledged)
    );

  return new Set(counted.map((advisory) => advisory.key)).size;
};
