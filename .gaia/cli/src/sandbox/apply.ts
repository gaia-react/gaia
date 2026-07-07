/**
 * Deep-merge helper for `gaia sandbox apply` (UAT-007).
 *
 * Pure: merges the sandbox seed fragment into an arbitrary existing
 * settings object, preserving every unrelated top-level key and any
 * pre-existing nested `sandbox.*` keys the adopter already set (this is a
 * seed, not a config manager, so it merges rather than clobbers). Array
 * values (e.g. `allowedDomains`) are replaced wholesale, not merged
 * element-wise. The CLI handler in `./index.ts` does the file IO around
 * this.
 */
import type {SandboxSettingsFragment} from './seed.js';

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const deepMerge = (
  target: Record<string, unknown>,
  source: Record<string, unknown>
): Record<string, unknown> => {
  const result: Record<string, unknown> = {...target};

  for (const [key, sourceValue] of Object.entries(source)) {
    const targetValue = result[key];

    result[key] =
      isPlainObject(targetValue) && isPlainObject(sourceValue) ?
        deepMerge(targetValue, sourceValue)
      : sourceValue;
  }

  return result;
};

export const mergeSandboxSettings = (
  existing: Record<string, unknown>,
  fragment: SandboxSettingsFragment
): Record<string, unknown> => deepMerge(existing, fragment);
