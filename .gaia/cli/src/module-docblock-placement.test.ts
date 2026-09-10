/**
 * Maintainer guard: a module docblock precedes the file's first import.
 *
 * A `/** … *\/` block placed *below* the first import no longer documents the
 * module. JSDoc binds by adjacency, so it attaches to whatever follows it,
 * usually the next `import` statement, and the file's primary explanation is
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
 * A JSDoc comment inside the file's LEADING import block that is followed by a
 * blank line or by another import. Both are positions no author picks for a
 * declaration's JSDoc, so both indicate a module docblock that the sort has
 * stranded.
 *
 * The leading import block is the header region only: the run of import
 * declarations at the top of the file, as the TypeScript parser reads them,
 * ending at the first statement of any other kind. An import declaration is
 * `import … from`, a side-effect `import '…'`, `import type`, or
 * `import x = …` (a `require(…)` or a namespace alias) with or without
 * `export`; `import.meta` and a dynamic `import(…)` are expressions and close
 * the header like any other statement. Comments and blank lines are trivia to
 * the parser, so they never close it. A file may open with its docblock,
 * import, and then import again further down beside the code that needs it
 * (`setup-ci/__tests__/sandbox.ts`); the later import is not part of the header
 * and a JSDoc beside it is not this defect.
 *
 * # Why the header is read from the TypeScript AST
 *
 * Where a statement ends is a parser's question. A line scanner has to find
 * terminators and comment boundaries in raw text, and every comment or string
 * shape it does not model moves a boundary without a sound: a `;` inside a
 * comment ends an import early, a block comment left open across lines hides
 * one, and `import (` reads as a declaration. Stripping comments correctly also
 * needs string awareness, since `import x from 'https://cdn/x.js';` would lose
 * its specifier to a naive `//` strip, and that is a tokenizer. So the guard
 * uses the compiler's own: statements from `ts.createSourceFile`, and each
 * statement's comments from `ts.getLeadingCommentRanges`.
 *
 * `typescript` resolves here as this workspace's devDependency, which holds only
 * while the guard stays test-resident. Moving it into shipped CLI source would
 * need `typescript` in `dependencies`.
 *
 * # Scope boundary (v1), and it is a floor rather than a clean bill of health
 *
 * A docblock leading the first declaration, with no blank line between them, is
 * NOT reported, because at that position a module docblock and an ordinary
 * JSDoc for that declaration are textually identical and only a reader can tell
 * them apart. `schemas/zod-error.ts` documents its one export from there and is
 * correct; `release/exclude-parser-parity.test.ts` describes the whole file from
 * there and arguably is not. Reporting the position would make the guard demand
 * that every documented first export lose its JSDoc, so the ambiguous case is
 * deliberately left to judgment.
 *
 * Repair, when this goes red: move the reported docblock to line 1, above every
 * import. `eslint --fix` leaves it there; the sort has no reason to move a
 * comment that precedes the block it sorts.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the suite skips
 * there. Mirrors `command-reachability.test.ts`.
 */
import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';
import {collectTreeFiles, TS_SOURCE_EXTENSIONS} from './util/tree-walk.js';

const isImport = (node: ts.Node): boolean =>
  ts.isImportDeclaration(node) || ts.isImportEqualsDeclaration(node);

/**
 * Reports the 1-based line of the first stranded module docblock, or `null`
 * when the file's header is well-formed.
 *
 * A comment opening on the same line as the previous statement's end is not
 * among the next statement's leading comments: it trails the statement before
 * it. No author puts a module docblock there, so the guard does not look.
 */
const findStrandedDocblock = (source: string): null | number => {
  const file = ts.createSourceFile(
    'module.ts',
    source,
    ts.ScriptTarget.Latest,
    false,
    ts.ScriptKind.TS
  );
  const lineStarts = file.getLineStarts();
  const lineOf = (position: number): number =>
    file.getLineAndCharacterOfPosition(position).line;
  const isBlankFrom = (position: number): boolean =>
    source
      .slice(position, lineStarts[lineOf(position) + 1] ?? source.length)
      .trim() === '';

  // The end-of-file token leads with whatever follows the last statement, so a
  // docblock below a file that is all imports is still read. A non-import
  // returns, so every node past the first has only imports before it.
  for (const [index, node] of [
    ...file.statements,
    file.endOfFileToken,
  ].entries()) {
    for (const comment of ts.getLeadingCommentRanges(source, node.pos) ?? []) {
      // A docblock sharing its line with code is attached to that code, so the
      // blank-line test applies only when the statement it leads starts on a
      // later line; a trailing comment on the docblock's line is not code. The
      // end-of-file token is exempt because it can start on that same line in
      // a file with no final newline, where nothing follows at all.
      const endsItsLine =
        node === file.endOfFileToken ||
        lineOf(node.getStart(file)) > lineOf(comment.end);
      const lineBelow = lineStarts[lineOf(comment.end) + 1] ?? source.length;
      // An empty `/**/` opens with `/**` but is not JSDoc: the TypeScript
      // scanner makes the same fourth-character test before reading one.
      const isDocblock =
        source.startsWith('/**', comment.pos) &&
        source.charAt(comment.pos + 3) !== '/';

      if (
        index > 0 &&
        isDocblock &&
        (isImport(node) || (endsItsLine && isBlankFrom(lineBelow)))
      ) {
        return lineOf(comment.pos) + 1;
      }
    }

    if (!isImport(node)) {
      return null;
    }
  }

  return null;
};

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const sourcesPresent = existsSync(cliSrc);

describe('module docblock placement', () => {
  // Maintainer-only guard: `sourcesPresent` is false on an adopter clone,
  // where `.gaia/cli/src` is release-excluded.
  test.skipIf(!sourcesPresent)(
    'every module docblock precedes the first import',
    () => {
      const sources = collectTreeFiles(cliSrc, TS_SOURCE_EXTENSIONS);

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
  test.each<[string, string[], number]>([
    [
      'reports a docblock stranded between imports',
      [
        "import {z} from 'zod';",
        '/**',
        ' * What this module is.',
        ' */',
        "import fs from 'node:fs';",
        '',
        'export const value = 1;',
      ],
      2,
    ],
    [
      'reports a docblock stranded below the whole import block',
      [
        "import {z} from 'zod';",
        '',
        '/**',
        ' * What this module is.',
        ' */',
        '',
        'export const value = 1;',
      ],
      3,
    ],
    [
      'reports a docblock stranded below a file that is all imports',
      [
        "import {z} from 'zod';",
        "import fs from 'node:fs';",
        '',
        '/**',
        ' * What this module is.',
        ' */',
        '',
      ],
      4,
    ],
    [
      'reports a docblock at the end of a file with no final newline',
      ["import {z} from 'zod';", '', '/**', ' * What this module is.', ' */'],
      3,
    ],
    // A comment between the docblock and its import must not hide it: that is
    // the shape an `import/order` group banner or an `eslint-disable-next-line`
    // produces.
    [
      'reports a docblock stranded above a commented import',
      [
        "import {z} from 'zod';",
        '/**',
        ' * What this module is.',
        ' */',
        '// Node builtins',
        "import fs from 'node:fs';",
        '',
        'export const value = 1;',
      ],
      2,
    ],
  ])('%s', (_label, lines, expected) => {
    expect(findStrandedDocblock(lines.join('\n'))).toBe(expected);
  });

  // A trailing comment on the import above must not hide the docblock below
  // it, or one `// eslint-disable-line` added by ordinary editing disables the
  // guard for that whole file.
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

  // An indented comment is still trivia, so it must not close the header, or
  // anything stranded below it reads as clean.
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

  // An identifier that merely starts with `import` is an ordinary statement,
  // so it closes the header and the docblock below it is not stranded. The
  // trailing blank line is what makes this discriminate: without it the
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

  // `import.meta` is an expression, not a declaration, so it closes the header.
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

  // A dynamic `import(...)` is an expression, not a declaration, so the
  // docblock above it is JSDoc for that call and the header has closed.
  test('a dynamic import call closes the header', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * Doc for the dynamic import below.',
      ' */',
      "import('./side-effect.js');",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // Whitespace before the paren still spells a dynamic import expression, so
  // the docblock above it is JSDoc for that call and the header has closed.
  test('a dynamic import call spelled with a space closes the header', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * Doc for the dynamic import below.',
      ' */',
      "import ('./side-effect.js');",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // A trailing block comment closing on a later line hides the import's
  // terminator from a line reader, which runs past this docblock to the next
  // import's terminator and steps over it.
  test('reports a docblock below an import whose trailing comment spans lines', () => {
    const source = [
      "import {z} from 'zod'; /* a",
      '   b */',
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(3);
  });

  // A `;` inside a comment on a continuation line does not end the import.
  // Reading it as the end makes `} from 'x';` the first non-import statement,
  // which closes the header above the docblock stranded below it.
  test('reports a docblock below a multi-line import with a commented semicolon', () => {
    const source = [
      'import {',
      '  a, // see foo;',
      "} from 'x';",
      '/**',
      ' * What this module is.',
      ' */',
      "import fs from 'node:fs';",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(4);
  });

  // The scope boundary counts `import x = require(…)` as a header import, so a
  // docblock between it and the next import is stranded like any other.
  test('treats an import-equals declaration as part of the header', () => {
    const source = [
      "import fs = require('node:fs');",
      '/**',
      ' * What this module is.',
      ' */',
      "import {z} from 'zod';",
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
  });

  // An import-prefixed identifier below a docblock is not an import, so the
  // docblock is JSDoc for the call it sits on rather than stranded.
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

  // An empty `/**/` between header imports is a plain block comment, so it
  // strands nothing and the move-to-line-1 repair would not apply to it.
  test('ignores an empty block comment between header imports', () => {
    const source = [
      "import {z} from 'zod';",
      '/**/',
      "import fs from 'node:fs';",
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

  // A docblock sharing its closing line with the declaration it documents is
  // attached to that declaration, whatever the line below it holds.
  test('accepts a docblock on the same line as the declaration it documents', () => {
    const source = [
      "import {z} from 'zod';",
      '/** What the export beside it does. */ export const value = 1;',
      '',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBeNull();
  });

  // A trailing comment on a docblock's closing line is not code, so it attaches
  // the docblock to nothing and the blank line below still strands it.
  test('reports a docblock whose closing line carries a trailing comment', () => {
    const source = [
      "import {z} from 'zod';",
      '/**',
      ' * What this module is.',
      ' */ // note',
      '',
      'export const value = 1;',
    ].join('\n');

    expect(findStrandedDocblock(source)).toBe(2);
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
