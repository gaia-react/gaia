/**
 * The recursive tree walk every whole-tree guard suite scans with.
 *
 * A guard's corpus is exactly the set it is trusted to have scanned, and a
 * per-suite copy of the walk drifts out from under that trust in silence:
 * near-identical functions are not identical ones, so no lint rule reports a
 * copy that stops normalizing separators, and an exclusion or a filter added
 * to one copy reaches none of the others.
 */
import {readdirSync} from 'node:fs';
import path from 'node:path';

/** The extension set the TypeScript-only guard suites scan with. */
export const TS_SOURCE_EXTENSIONS: ReadonlySet<string> = new Set(['.ts']);

/**
 * The extension argument that keeps every regular file, an extensionless one
 * and a dotfile included, which no extension set can name.
 */
export const EVERY_EXTENSION = 'every-extension';

/**
 * `entry` with `separator` rewritten to POSIX `/`.
 *
 * The separator is a parameter so that this has a falsifiable test. `path.sep`
 * is `/` on every platform this repository runs on, so a test that feeds a
 * native-separator entry through `collectTreeFiles` passes just as well with
 * the rewrite deleted, and the one property a caller depends on ends up
 * guarded by nothing. A test hands this a Windows separator directly.
 */
export const normalizeEntry = (entry: string, separator: string): string =>
  entry.split(separator).join('/');

/**
 * Every regular file under `root` whose extension is in `extensions`, relative
 * to `root`, separators normalized to POSIX, sorted.
 *
 * The extension set is a required parameter rather than a default, because a
 * default is how a caller that meant "everything" silently gets a narrower
 * corpus and reads the resulting empty answer as a clean pass. A caller that
 * does mean everything says so with `EVERY_EXTENSION`, for the same reason.
 *
 * Normalization is unconditional: a POSIX-separated entry is correct for every
 * caller, and a caller that compares an entry against a repo-relative module
 * path breaks without it.
 *
 * Only regular files are reported, so a caller may read each entry without
 * stating it first: a directory whose own name carries a matching extension
 * would otherwise reach `readFileSync` and throw `EISDIR`.
 *
 * A symlink is neither reported nor descended, whether it points at a file or
 * a directory, and a caller that needs to follow one owns that stat. The walk
 * recurses by hand rather than passing `recursive: true` to `readdirSync`
 * because that option descends a symlinked directory and reports what sits
 * under it as regular files, so a caller that rewrites its entries, as the
 * release scrub does, would write outside the root it named.
 *
 * No directory is excluded. A caller that walks a tree holding a build or
 * vendor directory owns that filter, which is the honest shape while no caller
 * does: an exclusion carried here for no live caller is a rule nobody can
 * check.
 *
 * A `root` that does not exist throws, the way `readdirSync` does. Silence
 * there would be the discovery-stage fail-open this walk exists to close.
 */
export const collectTreeFiles = (
  root: string,
  extensions: ReadonlySet<string> | typeof EVERY_EXTENSION
): readonly string[] => {
  const walk = (directory: string): string[] =>
    readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
      const absolute = path.join(directory, entry.name);

      if (entry.isDirectory()) {
        return walk(absolute);
      }

      return (
          entry.isFile() &&
            (extensions === EVERY_EXTENSION ||
              extensions.has(path.extname(entry.name).toLowerCase()))
        ) ?
          [normalizeEntry(path.relative(root, absolute), path.sep)]
        : [];
    });

  return walk(root).toSorted((a, b) => a.localeCompare(b));
};
