/**
 * Maintainer guard: a module docblock precedes the file's first import.
 *
 * A `/** … *\/` block placed *below* the first import no longer documents the
 * module. JSDoc binds by adjacency, so it attaches to whatever follows it —
 * usually the next `import` statement — and the file's primary explanation is
 * silently misattributed to a dependency.
 *
 * # Why this needs a guard rather than a sweep
 *
 * The class recreates itself out of ordinary editing, so fixing the instances
 * alone buys a diff that decays. Imports are sorted by specifier, and a
 * docblock written above what was then the first import is left behind the
 * moment an import that sorts higher is added. Nobody chooses this and nothing
 * reports it: 81 files had accumulated when `#1163` measured the class, against
 * a single instance (`#1034`) that had been fixed one-at-a-time on the
 * assumption it was unique.
 *
 * The convention is therefore asserted rather than merely swept: 126 files led
 * with their docblock deliberately, and every file that did not was an artifact
 * of the sort. `#1034` had already accepted the correctness argument.
 *
 * # What counts as an offense
 *
 * A `/**`-opening block comment inside the file's LEADING import block that is
 * followed by a blank line or by another import. Both are positions no author
 * picks for a declaration's JSDoc, so both indicate a module docblock that the
 * sort has stranded.
 *
 * The leading import block is the header region only: it ends at the first
 * statement that is not an import, a comment, or blank. A file may open with
 * its docblock, import, and then import again further down beside the code that
 * needs it (`setup-ci/__tests__/sandbox.ts`); the later import is not part of
 * the header and a JSDoc beside it is not this defect.
 *
 * # Scope boundary (v1), and it is a floor rather than a clean bill of health
 *
 * A docblock sitting immediately above the first declaration — no blank line
 * between them — is NOT reported, because at that position a module docblock
 * and an ordinary JSDoc for that declaration are textually identical and only a
 * reader can tell them apart. `schemas/zod-error.ts` documents its one export
 * from there and is correct; `release/exclude-parser-parity.test.ts` describes
 * the whole file from there and arguably is not. Reporting the position would
 * make the guard demand that every documented first export lose its JSDoc, so
 * the ambiguous case is deliberately left to judgment.
 *
 * Repair, when this goes red: move the reported docblock to line 1, above every
 * import. `eslint --fix` leaves it there; the sort has no reason to move a
 * comment that precedes the block it sorts.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the suite skips
 * there. Mirrors `command-reachability.test.ts`.
 */
import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

/** Line index of the `*\/` closing the block comment opened at `start`. */
const blockCommentEnd = (lines: readonly string[], start: number): number => {
  let end = start;

  while (end < lines.length && !(lines[end] ?? '').includes('*/')) {
    end += 1;
  }

  return end;
};

/**
 * Line index of the last line of the import statement opening at `start`.
 * A multi-line `import {…} from '…';` ends on its own closing line, so the
 * scan runs to the first line that terminates a statement.
 */
const importEnd = (lines: readonly string[], start: number): number => {
  let end = start;

  while (end < lines.length && !(lines[end] ?? '').trimEnd().endsWith(';')) {
    end += 1;
  }

  return end;
};

/**
 * Whether the line following a docblock leaves it attached to nothing. A blank
 * line detaches it outright, and an `import` makes it JSDoc for a dependency.
 */
const detachesDocblock = (next: string): boolean =>
  next.trim() === '' || next.startsWith('import');

/**
 * Reports the 1-based line of the first stranded module docblock, or `null`
 * when the file's header is well-formed. Exported for the fixture tests below,
 * which are what prove this can report anything at all.
 */
export const findStrandedDocblock = (source: string): null | number => {
  const lines = source.split('\n');
  let index = 0;
  let sawImport = false;

  while (index < lines.length) {
    const line = lines[index] ?? '';

    if (line.trim() === '' || line.startsWith('//')) {
      index += 1;
    } else if (line.startsWith('/*')) {
      const end = blockCommentEnd(lines, index);

      if (
        sawImport &&
        line.startsWith('/**') &&
        detachesDocblock(lines[end + 1] ?? '')
      ) {
        return index + 1;
      }

      index = end + 1;
    } else if (line.startsWith('import')) {
      sawImport = true;
      index = importEnd(lines, index) + 1;
    } else {
      // The first non-import statement closes the header region.
      return null;
    }
  }

  return null;
};

const collectSourceFiles = (root: string): readonly string[] =>
  (readdirSync(root, {recursive: true}) as string[])
    .filter((entry) => entry.endsWith('.ts'))
    .toSorted((a, b) => a.localeCompare(b));

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const sourcesPresent = existsSync(cliSrc);

describe('module docblock placement', () => {
  // Maintainer-only guard: `sourcesPresent` is false on an adopter clone,
  // where `.gaia/cli/src` is release-excluded.
  test.skipIf(!sourcesPresent)(
    'every module docblock precedes the first import',
    () => {
      const stranded = collectSourceFiles(cliSrc).flatMap((relative) => {
        const line = findStrandedDocblock(
          readFileSync(path.join(cliSrc, relative), 'utf8')
        );

        return line === null ? [] : [`.gaia/cli/src/${relative}:${line}`];
      });

      expect(stranded).toEqual([]);
    }
  );

  // No `skipIf`: these run against fixture strings, so they hold on any clone
  // and they are what establish that the detector above can report at all.
  // A corpus that happens to be clean would otherwise green a broken detector.
  test('reports a docblock stranded between imports', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
  });

  test('reports a docblock stranded below the whole import block', () => {
    const source = [
      "import {z} from 'zod';",
      '',
      '/**',
      ' * What this module is.',
      ' */',
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(3);
  });

  test('accepts a docblock above the first import', () => {
    const source = [
      '/**',
      ' * What this module is.',
      ' */',
      "import {z} from 'zod';",
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // The scope boundary, pinned so a later widening is a deliberate act rather
  // than an accident: at this position the docblock is indistinguishable from
  // JSDoc for the declaration it sits on.
  test('accepts a docblock attached to the first declaration', () => {
    const source = [
      "import {z} from 'zod';",
      '',
      '/**',
      ' * What the export below does.',
      ' */',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // A second import block beside the code that needs it is not the header, so
  // a JSDoc down there is an ordinary one. Without this the detector would
  // report `setup-ci/__tests__/sandbox.ts`, whose docblock is already correct.
  test('ignores a JSDoc beside a later, non-header import', () => {
    const source = [
      '/**',
      ' * What this module is.',
      ' */',
      "import {z} from 'zod';",
      '',
      'export const first = 1;',
      '',
      '/** Doc for the helper. */',
      'export const helper = () => 2;',
      '',
      "import fs from 'node:fs';",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  test('ignores a file with no imports at all', () => {
    const source = [
      '/**',
      ' * Constants.',
      ' */',
      '',
      'export const x = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });
});
