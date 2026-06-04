/**
 * Manifest parser for `gaia update merge`.
 *
 * The shipped manifest at `.gaia/manifest.json` carries a `files` map
 * keyed by repo-relative path with one of three classes:
 *
 *   - `owned`      : GAIA controls fully.
 *   - `shared`     : GAIA seeds, adopter customizes.
 *   - `wiki-owned` : GAIA-seeded wiki page; adopter may edit.
 *
 * The interface contract for `gaia update merge` collapses
 * `wiki-owned` into the `shared` decision branch (same drift
 * handling per the existing skill text). We surface a normalized
 * three-class enum so callers do not need to reason about the
 * collapse rule themselves.
 */
import {existsSync, readFileSync} from 'node:fs';

/** Class as it appears in the on-disk manifest. */
export type RawManifestClass = 'owned' | 'shared' | 'wiki-owned';

/**
 * Class normalized for `gaia update merge` decision branches.
 *
 * - `upstream` : formerly contributed but never paired with `--manifest` data;
 *   reserved so the `UpdateMergeReport.conflicts[].class` discriminator can
 *   represent every interface-contract value without invention.
 * - `owned`    : adopter-customized; GAIA never auto-edits.
 * - `shared`   : three-way candidate; raw `wiki-owned` collapses to this.
 *
 * The three values match the `class` discriminator on
 * `UpdateMergeReport.conflicts[]` in the README contract.
 */
export type NormalizedClass = 'owned' | 'shared' | 'upstream';

export type ManifestEntry = {
  rawClass: RawManifestClass;
  normalizedClass: NormalizedClass;
};

export type Manifest = {
  /** Manifest version field (passed through; not validated). */
  version: string | undefined;
  files: Map<string, ManifestEntry>;
};

export type ManifestParseFailure = {
  ok: false;
  message: string;
};

export type ManifestParseSuccess = {
  ok: true;
  manifest: Manifest;
};

export type ManifestParseResult = ManifestParseFailure | ManifestParseSuccess;

const VALID_RAW_CLASSES = new Set<RawManifestClass>([
  'owned',
  'shared',
  'wiki-owned',
]);

const normalizeClass = (rawClass: RawManifestClass): NormalizedClass => {
  if (rawClass === 'owned') return 'owned';
  // Both `shared` and `wiki-owned` follow the three-way merge branch
  // per the existing decision table in the update-gaia skill.
  return 'shared';
};

type RawManifestShape = {
  files?: unknown;
  version?: unknown;
};

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/**
 * Read and validate `.gaia/manifest.json` at the supplied path.
 * Returns a normalized result with class lookups indexed by path.
 */
export const loadManifest = (manifestPath: string): ManifestParseResult => {
  if (!existsSync(manifestPath)) {
    return {
      ok: false,
      message: `manifest not found: ${manifestPath}`,
    };
  }

  let raw: string;

  try {
    raw = readFileSync(manifestPath, 'utf8');
  } catch (error) {
    return {
      ok: false,
      message: `failed to read manifest: ${
        error instanceof Error ? error.message : String(error)
      }`,
    };
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return {
      ok: false,
      message: `manifest is not valid JSON: ${
        error instanceof Error ? error.message : String(error)
      }`,
    };
  }

  if (!isObject(parsed)) {
    return {ok: false, message: 'manifest root is not an object'};
  }

  const shape = parsed as RawManifestShape;

  if (!isObject(shape.files)) {
    return {ok: false, message: 'manifest.files is missing or not an object'};
  }

  const files = new Map<string, ManifestEntry>();

  for (const [path, value] of Object.entries(shape.files)) {
    if (typeof value !== 'string') {
      return {
        ok: false,
        message: `manifest.files["${path}"] is not a string`,
      };
    }

    if (!VALID_RAW_CLASSES.has(value as RawManifestClass)) {
      return {
        ok: false,
        message: `manifest.files["${path}"] has unknown class: "${value}"`,
      };
    }

    const rawClass = value as RawManifestClass;
    files.set(path, {
      normalizedClass: normalizeClass(rawClass),
      rawClass,
    });
  }

  const version = typeof shape.version === 'string' ? shape.version : undefined;

  return {
    ok: true,
    manifest: {files, version},
  };
};

/**
 * Look up a file's normalized class. Returns `null` when the path is
 * not in the manifest (i.e. adopter-owned implicitly).
 */
export const lookupClass = (
  manifest: Manifest,
  path: string
): NormalizedClass | null => manifest.files.get(path)?.normalizedClass ?? null;
