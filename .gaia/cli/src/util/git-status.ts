/**
 * Shared `git status --porcelain -z` record parser.
 *
 * One copy, because two callers need the same answer from the same command:
 * `update/regen-regions.ts` compares a region's writes against its declared
 * paths, and `wiki/util/branch.ts` classifies a working tree as wiki or
 * non-wiki. A second hand-rolled copy is how one of them keeps a defect the
 * other has already fixed.
 */
import {splitZStream} from './git-z.js';

/**
 * The paths named by a `git status --porcelain -z` stream, status columns
 * stripped, rename and copy origins included.
 *
 * `-z` is the caller's half of the contract and it is load-bearing, not a
 * formatting preference. Without it git applies C-style quoting
 * (`core.quotePath` is on by default), so a path carrying a space, a quote, or
 * a non-ASCII byte arrives wrapped in `"` with its bytes escaped, and a rename
 * arrives as one ambiguous `old -> new` payload that cannot be split on ` -> `
 * without corrupting a name containing it. Under `-z` git never quotes and a
 * rename emits its origin path as its own trailing record, so both hazards
 * disappear rather than needing to be undone. Nothing here unquotes, and
 * nothing here splits on ` -> `; a caller that drops `-z` gets raw quoted bytes
 * back rather than a repaired path.
 *
 * A rename or copy record is followed by that bare origin-path record, which
 * carries no `XY ` status prefix, so the stream needs a one-record lookahead.
 * The flag is cleared before the next record is classified, which is what keeps
 * an origin path whose own first two characters contain `R` or `C`
 * (`Config/old`) from being read as a status record.
 */
export const porcelainZPaths = (out: string): string[] => {
  const paths: string[] = [];
  let expectOriginPath = false;

  splitZStream(out).forEach((record) => {
    if (expectOriginPath) {
      expectOriginPath = false;
      paths.push(record);

      return;
    }

    expectOriginPath = /[CR]/u.test(record.slice(0, 2));
    paths.push(record.slice(3));
  });

  return paths;
};
