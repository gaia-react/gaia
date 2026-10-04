/**
 * Validators for every field the advisories payload keeps from Dependabot
 * alerts and `pnpm audit`. Both sources are untrusted: a value that fails its
 * check drops the whole record, so nothing outside these grammars reaches the
 * payload or the model that reads it.
 */
import semver from 'semver';

export type AdvisoryRelationship =
  'direct' | 'inconclusive' | 'n/a' | 'transitive' | 'unknown';

export type AdvisoryScope = 'development' | 'n/a' | 'runtime';

export type AdvisorySeverity = 'critical' | 'high' | 'low' | 'medium';

const GHSA_PATTERN = /^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$/u;

// npm's name grammar, with uppercase admitted for the legacy packages that
// predate the lowercase rule. Every character outside it, a space or a shell
// metacharacter included, fails.
const NPM_NAME_PATTERN =
  /^(?:@[a-z0-9~-][a-z0-9._~-]*\/)?[A-Za-z0-9~-][A-Za-z0-9._~-]*$/u;
const NPM_NAME_MAX_LENGTH = 214;

const RANGE_PATTERN = /^[0-9A-Za-z.*^~<>=|, -]+$/u;
const MANIFEST_PATH_PATTERN = /^[A-Za-z0-9._/@-]+$/u;

// Generous bounds: no real version, range, or manifest path comes near them,
// and they keep a hostile megabyte string out of the semver parser.
const VERSION_MAX_LENGTH = 256;
const RANGE_MAX_LENGTH = 512;
const MANIFEST_PATH_MAX_LENGTH = 512;

/** True for a GitHub advisory id. */
export const isGhsaId = (value: unknown): value is string =>
  typeof value === 'string' && GHSA_PATTERN.test(value);

/** True for a string in npm's package-name grammar. */
export const isNpmPackageName = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.length <= NPM_NAME_MAX_LENGTH &&
  NPM_NAME_PATTERN.test(value);

/** True for a strict semver version (no range, no leading `v`). */
export const isSemverVersion = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.length <= VERSION_MAX_LENGTH &&
  semver.valid(value) === value;

/**
 * GitHub writes a range with comma-separated comparators (`>= 4.0.0, < 4.1.0`),
 * which the semver parser does not read; a space is semver's AND, so the
 * commas become spaces before any range is evaluated.
 */
export const toSemverRange = (range: string): string =>
  range.replaceAll(',', ' ');

/** True for a range limited to the range alphabet that semver can parse. */
export const isRangeString = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.trim().length > 0 &&
  value.length <= RANGE_MAX_LENGTH &&
  RANGE_PATTERN.test(value) &&
  semver.validRange(toSemverRange(value)) !== null;

/** True for a repository-relative manifest path with no `..` segment. */
export const isManifestPath = (value: unknown): value is string =>
  typeof value === 'string' &&
  value.length <= MANIFEST_PATH_MAX_LENGTH &&
  MANIFEST_PATH_PATTERN.test(value) &&
  !value.startsWith('/') &&
  value.split('/').every((segment) => segment !== '..' && segment !== '');

/** True for a positive safe integer (alert numbers, pnpm advisory ids). */
export const isPositiveInteger = (value: unknown): value is number =>
  typeof value === 'number' && Number.isSafeInteger(value) && value > 0;

const SEVERITY_BY_INPUT: Readonly<Record<string, AdvisorySeverity>> = {
  critical: 'critical',
  high: 'high',
  low: 'low',
  medium: 'medium',
  moderate: 'medium',
};

/** The severity enum, with pnpm's `moderate` read as `medium`; null otherwise. */
export const normalizeSeverity = (value: unknown): AdvisorySeverity | null =>
  typeof value === 'string' && Object.hasOwn(SEVERITY_BY_INPUT, value) ?
    (SEVERITY_BY_INPUT[value] ?? null)
  : null;

/**
 * The alert scope enum. GitHub reports `null` when it cannot tell, which reads
 * as `n/a` rather than rejecting a real alert; any other value is null.
 */
export const normalizeScope = (value: unknown): AdvisoryScope | null => {
  if (value === null || value === undefined) return 'n/a';
  if (value === 'runtime' || value === 'development') return value;

  return null;
};

/**
 * The alert relationship enum. GitHub reports `null` when it cannot tell,
 * which reads as `unknown`; any other value is null.
 */
export const normalizeRelationship = (
  value: unknown
): AdvisoryRelationship | null => {
  if (value === null || value === undefined) return 'unknown';

  return (
      value === 'direct' ||
        value === 'inconclusive' ||
        value === 'transitive' ||
        value === 'unknown'
    ) ?
      value
    : null;
};
