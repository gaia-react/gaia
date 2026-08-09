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
 * A statement terminator, tolerating a trailing comment that closes on the same
 * line.
 *
 * A bare `endsWith(';')` misses `import x from 'y'; // note`, and missing it is
 * not a near-miss: the scan then runs past the docblock below that import to
 * the NEXT import's terminator, steps over the docblock entirely, and the guard
 * reports the file clean on exactly the defect it exists to catch. One
 * `// eslint-disable-line` added by ordinary editing would have disabled this
 * guard for that whole file, silently.
 *
 * Two shapes are outside it, both known and both failing silent-green (#1273's
 * sibling, tracked): a trailing block comment left open to a later line, and a
 * `;` appearing inside a comment on a continuation line of a multi-line import,
 * which terminates that import early. Closing either means stripping comment
 * content before the test, and doing that correctly needs string awareness as
 * well, since `import x from 'https://cdn/x.js';` would otherwise have its
 * specifier eaten. That is a tokenizer, and a tokenizer is the argument for
 * reading this from the TypeScript AST rather than from lines at all.
 */
const STATEMENT_END = /;\s*(?:\/\/.*|\/\*.*\*\/)?$/;

/**
 * `import` as a whole word, so neither `importantThing();` nor `import.meta`
 * is read as an import declaration. `\b` is not enough: it matches between `t`
 * and `.`, so `import.meta.hot?.accept();` would hold the header open and the
 * docblock below it would be reported stranded when it is not.
 */
const IMPORT_START = /^import(?![.\w])/;

/**
 * Line index of the last line of the import statement opening at `start`.
 * A multi-line `import {…} from '…';` ends on its own closing line, so the
 * scan runs to the first line that terminates a statement.
 */
const importEnd = (lines: readonly string[], start: number): number => {
  let end = start;

  while (end < lines.length && !STATEMENT_END.test((lines[end] ?? '').trim())) {
    end += 1;
  }

  return end;
};

/**
 * Line index of the first line that carries a statement, skipping the content
 * the header treats as transparent: blank lines, `//` notes, and further block
 * comments. Returns `lines.length` when the file ends first.
 */
const nextStatement = (lines: readonly string[], from: number): number => {
  let index = from;

  while (index < lines.length) {
    const line = (lines[index] ?? '').trim();

    if (line === '' || line.startsWith('//')) {
      index += 1;
    } else if (line.startsWith('/*')) {
      index = blockCommentEnd(lines, index) + 1;
    } else {
      return index;
    }
  }

  return lines.length;
};

/**
 * Whether a docblock closing at `end` is left attached to nothing.
 *
 * A blank line immediately below detaches it outright. Otherwise the question
 * is what it actually binds to, which is the next STATEMENT rather than the
 * next line: an `import` makes it JSDoc for a dependency, and any other
 * statement is the ambiguous case the scope boundary leaves alone. Reading the
 * next line alone would let a `// group banner` between the docblock and its
 * import hide the very thing this guard exists to report.
 */
const detachesDocblock = (lines: readonly string[], end: number): boolean =>
  (lines[end + 1] ?? '').trim() === '' ||
  IMPORT_START.test((lines[nextStatement(lines, end + 1)] ?? '').trim());

/**
 * Reports the 1-based line of the first stranded module docblock, or `null`
 * when the file's header is well-formed.
 *
 * Every line is classified on its trimmed form. Classifying on the raw line
 * fails open in both directions: an indented `/**` falls through to the closing
 * branch and ends the header early, so a docblock stranded below it reads as
 * clean, while `importantThing();` matches a bare `startsWith('import')` and
 * holds the header open past where it closes.
 */
const findStrandedDocblock = (source: string): null | number => {
  const lines = source.split('\n');
  let index = 0;
  let sawImport = false;

  while (index < lines.length) {
    const line = (lines[index] ?? '').trim();

    if (line === '' || line.startsWith('//')) {
      index += 1;
    } else if (line.startsWith('/*')) {
      const end = blockCommentEnd(lines, index);

      if (sawImport && line.startsWith('/**') && detachesDocblock(lines, end)) {
        return index + 1;
      }

      index = end + 1;
    } else if (IMPORT_START.test(line)) {
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
      const sources = collectSourceFiles(cliSrc);

      // A scan that reaches nothing reports nothing, so the empty result below
      // would read as a clean corpus. `.gaia/cli/src` has held hundreds of
      // `.ts` files for the life of the CLI; a count this low means the walk
      // or the extension filter broke, not that the tree shrank.
      expect(sources.length).toBeGreaterThan(50);

      const stranded = sources.flatMap((relative) => {
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

  // A comment between the docblock and its import must not hide it. Reading
  // only the line below the docblock reported `null` here, which is the shape
  // an `import/order` group banner or an `eslint-disable-next-line` produces.
  test('reports a docblock stranded above a commented import', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * What this module is.',
      ' */',
      '// Node builtins',
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
  });

  // A trailing comment on the import above means the line does not end with
  // `;`. Scanning for a bare `;` ran past this docblock to the next import's
  // terminator and stepped over it, so the guard reported clean on the defect
  // it exists to catch.
  test('reports a docblock stranded below a commented import line', () => {
    const source = [
      "import {z} from 'zod'; // eslint-disable-line",
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
  });

  test('reports a docblock stranded below a block-commented import line', () => {
    const source = [
      "import {z} from 'zod'; /* keep */",
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
  });

  // Classifying on the raw line let an indented `/**` close the header early,
  // so anything stranded below it read as clean.
  test('does not let an indented block comment close the header', () => {
    const source = [
      "import {z} from 'zod';",
      '  /* an indented note */',
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(3);
  });

  // The mirror image: a bare `startsWith('import')` matched `importantThing();`
  // and held the header open past the statement that closes it, so the docblock
  // below was reported as stranded when the header had in fact already ended.
  // The trailing blank line is what makes this discriminate: without it the
  // docblock binds to the declaration and both readings agree on `null`.
  test('an import-prefixed identifier closes the header', () => {
    const source = [
      "import {z} from 'zod';",
      'importantThing();',
      '/**',
      ' * Not a module docblock: the header closed above.',
      ' */',
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // `\b` matches between `t` and `.`, so a word-boundary test alone reads
  // `import.meta` as an import declaration and holds the header open.
  test('an import.meta statement closes the header', () => {
    const source = [
      "import {z} from 'zod';",
      'import.meta.hot?.accept();',
      '/**',
      ' * Not a module docblock: the header closed above.',
      ' */',
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // Same word-boundary bug reached through the other caller: if the next
  // statement below a docblock is read as an import, the docblock is reported
  // stranded when it is really JSDoc for the call it sits on.
  test('an import-prefixed identifier does not detach the docblock above it', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * Doc for the call below.',
      ' */',
      'importantThing();',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
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
