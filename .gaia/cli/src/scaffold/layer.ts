/**
 * Domain-layer folder resolution, shared by the scaffolders that write into
 * or read from `app/services/<layer>/`.
 */
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';

/** Names of the directories directly under `dir`, sorted; empty when `dir` is absent. */
export const listSubdirectories = (dir: string): string[] =>
  existsSync(dir) ?
    readdirSync(dir, {withFileTypes: true})
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .toSorted((a, b) => a.localeCompare(b))
  : [];

/**
 * The `isSnakeCaseEnabled` property in a layer's `create()` call, with its
 * value in group 1. The `configure-data-layer` init step writes the flag and
 * the scaffolders read it, so both sides share this one pattern.
 */
export const SNAKE_CASE_FLAG = /isSnakeCaseEnabled\s*:\s*([^,}\s]+)/u;

/**
 * Whether the layer's request factory opts into snake_case wire conversion;
 * an absent `api.ts` reads as the camelCase default.
 */
export const isSnakeCaseLayer = (
  packageDir: string,
  layer: string
): boolean => {
  const api = path.join(packageDir, 'app', 'services', layer, 'api.ts');

  return (
    existsSync(api) &&
    SNAKE_CASE_FLAG.exec(readFileSync(api, 'utf8'))?.[1] === 'true'
  );
};

/**
 * The folder under `app/services/` holding the domain layer. The template
 * ships it as `gaia` and adopters rename it to their company or API name, so
 * it is discovered: `--layer` when passed, else the single directory there
 * other than the `api` wrapper. Zero or several candidates is an error naming
 * them, never a guess.
 */
export const resolveLayer = (
  packageDir: string,
  requested: string | undefined
): {error: string} | {layer: string} => {
  const servicesDir = path.join(packageDir, 'app', 'services');

  if (requested !== undefined) {
    const requestedDir = path.join(servicesDir, requested);

    return existsSync(requestedDir) && statSync(requestedDir).isDirectory() ?
        {layer: requested}
      : {error: `--layer folder not found: app/services/${requested}/`};
  }

  const candidates = listSubdirectories(servicesDir).filter(
    (name) => name !== 'api'
  );
  const [only] = candidates;

  if (candidates.length === 1 && only !== undefined) return {layer: only};

  const found = candidates.length === 0 ? 'none' : candidates.join(', ');

  return {
    error: `cannot pick the domain-layer folder under app/services/ (found: ${found}); pass --layer <folder>`,
  };
};
