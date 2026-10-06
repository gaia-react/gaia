/**
 * Domain-layer folder resolution, shared by the scaffolders that write into
 * or read from `app/services/<layer>/`.
 */
import {existsSync, readdirSync, statSync} from 'node:fs';
import path from 'node:path';

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

  const candidates =
    existsSync(servicesDir) ?
      readdirSync(servicesDir, {withFileTypes: true})
        .filter((entry) => entry.isDirectory() && entry.name !== 'api')
        .map((entry) => entry.name)
        .toSorted((a, b) => a.localeCompare(b))
    : [];
  const [only] = candidates;

  if (candidates.length === 1 && only !== undefined) return {layer: only};

  const found = candidates.length === 0 ? 'none' : candidates.join(', ');

  return {
    error: `cannot pick the domain-layer folder under app/services/ (found: ${found}); pass --layer <folder>`,
  };
};
