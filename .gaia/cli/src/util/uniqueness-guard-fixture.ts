/**
 * The corpus scan the declared-once guards under `.gaia/cli/src` share.
 *
 * Each of those guards asserts that one declaration exists in exactly one
 * module, and each needs the same scaffold around its own detector: resolve the
 * corpus, skip on a clone that does not carry it, floor the corpus size, exempt
 * the declaring module, and drive the detector against that declaration so a
 * detector matching nothing cannot green.
 *
 * Written per guard, that scaffold is the near-identical-copy class those very
 * guards exist to police, reproduced one layer up. The consequence is the one
 * the floor assertion exists to prevent, applied to the floor itself: a floor
 * lowered or a root narrowed in one copy leaves the other's untouched and
 * reports nothing, so a guard whose corpus has quietly shrunk still greens.
 *
 * Admission is a property, not a filename or a count: a guard belongs here when
 * it has a declaring module and a self-check against that declaration. Callers
 * are whatever `testDeclaredOnce` resolves to, and they are not confined to one
 * directory or to any naming convention. A whole-tree guard that scans a corpus
 * for some other shape of offense, with no declaring module and no self-check,
 * has neither, so serving it here would parameterize this on a property it
 * does not have.
 *
 * Test-only, and reached only from `*.test.ts` files: it imports vitest, and
 * the shipped binaries are bundled from `src/index.ts` and
 * `src/index.maintainer.ts`, so a shipped module importing this would pull the
 * test runner into a release artifact.
 */
import {expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './repo-root-fixture.js';
import {
  collectTreeFiles,
  normalizeEntry,
  TS_SOURCE_EXTENSIONS,
} from './tree-walk.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

/**
 * The corpus the uniqueness guards scan: the CLI's TypeScript sources.
 *
 * Resolved from this module's own location rather than handed in by its caller,
 * so it cannot end up scanning a different root. It has held hundreds of
 * `.ts` files for the life of the CLI, which is what makes a floor in the tens
 * a live signal rather than a formality.
 */
export const CLI_SRC = path.join(REPO_ROOT, '.gaia', 'cli', 'src');

type CorpusScan = {
  /** Absolute path of the tree to scan. */
  corpusRoot: string;
  /**
   * The one module allowed to carry the declaration, relative to `corpusRoot`
   * and spelled the way `collectTreeFiles` reports an entry. Any other spelling
   * makes the comparison miss, and the miss reports the shared declaration
   * itself as a copy of itself, which reads as the guard working.
   */
  declaringModule: string;
  /**
   * The caller's detector: the 1-based line of `source`'s first offense, or
   * `null` when it carries none.
   */
  findOffense: (source: string) => null | number;
  /**
   * Corpus entries this guard does not read, beyond `declaringModule`, as a
   * predicate over the same spelling `declaringModule` uses.
   *
   * A predicate rather than a list of names, because the cases that need it are
   * classes rather than entries: a corpus whose own test files carry the
   * declaration as fixture data is exempt by shape, and enumerating those files
   * would be a second list to keep in step. Omit it, as the callers that need
   * no such class do, and only the declaring module is spared.
   *
   * Every exemption is a hole in the guard, so a caller passing this owes the
   * reason at its own site: what it spares, and why sparing it does not spare
   * the drift the guard exists to catch.
   */
  isExempt?: (relative: string) => boolean;
};

type UniquenessGuard = {
  /**
   * The largest corpus this guard reads as a broken scan rather than as one
   * that ran: a real corpus has to come out strictly larger. A required
   * argument rather than a default, for the reason `collectTreeFiles` gives for
   * its own extension set: a default is how a caller silently gets a narrower
   * corpus and reads the resulting empty answer as a clean pass.
   */
  corpusFloor: number;
  /**
   * What the detector reports, as a verb phrase completing "no file outside the
   * declaring module …". This is the corpus test's name.
   */
  offense: string;
} & CorpusScan;

/**
 * Every offense outside the declaring module, as repo-relative `path:line`, and
 * the size of the corpus they were found in.
 *
 * The size rides along rather than being recounted by the caller, because a
 * second walk is a second chance for the two to disagree about what was
 * scanned.
 */
export const scanCorpus = (
  guard: CorpusScan
): {offenses: readonly string[]; size: number} => {
  const sources = collectTreeFiles(guard.corpusRoot, TS_SOURCE_EXTENSIONS);

  return {
    offenses: sources
      .filter(
        (relative) =>
          relative !== guard.declaringModule &&
          !(guard.isExempt?.(relative) ?? false)
      )
      .flatMap((relative) => {
        const absolute = path.join(guard.corpusRoot, relative);
        const line = guard.findOffense(readFileSync(absolute, 'utf8'));

        return line === null ?
            []
          : [
              `${normalizeEntry(path.relative(REPO_ROOT, absolute), path.sep)}:${line}`,
            ];
      }),
    size: sources.length,
  };
};

/**
 * Registers a uniqueness guard's corpus-driven tests inside the caller's
 * `describe`. The caller declares only its detector, its fixtures, and its
 * boundary-decision tests.
 */
export const testDeclaredOnce = (guard: UniquenessGuard): void => {
  // Maintainer-only guard: `.gaia/cli/src` is release-excluded, so the corpus
  // is absent on an adopter clone and both corpus tests skip there.
  const sourcesPresent = existsSync(guard.corpusRoot);

  test.skipIf(!sourcesPresent)(
    `no file outside the declaring module ${guard.offense}`,
    () => {
      const {offenses, size} = scanCorpus(guard);

      // A scan that reaches nothing reports nothing, so the empty result below
      // would read as a clean corpus. A size under the floor means the root,
      // the walk, or the extension filter broke, not that the tree shrank.
      expect(size).toBeGreaterThan(guard.corpusFloor);
      expect(offenses).toEqual([]);
    }
  );

  // The corpus above is expected to be empty, so on its own it would green just
  // as loudly with a detector that matches nothing. This is the one assertion
  // driven against the live declaration the guard is written for.
  test.skipIf(!sourcesPresent)('the declaring module itself matches', () => {
    const declaration = path.join(guard.corpusRoot, guard.declaringModule);

    expect(guard.findOffense(readFileSync(declaration, 'utf8'))).not.toBeNull();
  });
};
