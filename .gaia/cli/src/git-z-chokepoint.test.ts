/**
 * Maintainer guard: a git listing command's argv is built by `gitZArgs`.
 *
 * Under git's default `core.quotePath` a listing verb C-quotes any path
 * carrying a non-ASCII byte, and the quoted spelling names no file, so every
 * consumer of the output answers wrongly rather than failing. `util/git-z.ts`
 * owns the spelling that prevents it and its docblock carries the full why.
 * What it cannot do is make itself used: every git runner in this CLI accepts a
 * raw argv, so an author writing a listing call from muscle memory bypasses the
 * helper without noticing. Every instance of the class in this source was found
 * by reading, including one written after the helper existed, and
 * `.gaia/scripts/lint-git-path-quoting.sh`, the guard for the same class on the
 * shell surfaces, reads no TypeScript.
 *
 * # What counts as an offense
 *
 * A string literal naming a listing verb, standing as an element of an array
 * literal: the shape of a raw git argv. A wrapper that leaves the element's
 * value the verb (parentheses, a type assertion, `as`, `satisfies`, a
 * conditional branch) still counts. The verb a `gitZArgs(verb, …)` call
 * names is a call argument rather than an array element, so every routed call
 * passes by construction and no allowlist of callers is needed.
 *
 * The verb set is the set `gitZArgs` serves. A test below derives the verbs its
 * callers pass and fails when one is missing from `LISTING_VERBS`, so a verb
 * newly routed through the helper is guarded from the change that routes it.
 *
 * The literal is read from the TypeScript AST because the formatter routinely
 * spreads an argv across lines, putting the verb on a line with nothing else
 * that identifies a git call, and a line scanner reading it has to model
 * strings and comments to avoid misreading ordinary text. `typescript` resolves
 * here as this workspace's devDependency, which holds only while the guard
 * stays test-resident.
 *
 * # The exemption
 *
 * A call that must stay unquoted, a canary proving its fixture path really is
 * C-quoted so the assertion beside it can fail, carries a line comment opening
 * `gaia-lint-ignore git-z-chokepoint:` followed by its reason, in the comment
 * run directly above its statement. A blank line ends that run. The reason is
 * mandatory and a marker exempting nothing is reported: the two properties the
 * shell guards' pragma carries, for the same reason, since without them a
 * marker decays into a blanket exemption nobody re-reads. A blanket exemption
 * for test files is refused outright, because a test is exactly where an
 * unrouted listing call has shipped.
 *
 * `util/git-z.test.ts` is exempt by path. It asserts the helper's literal
 * output, so its arrays are the specification rather than calls. The helper
 * itself needs no exemption: it takes the verb as a parameter and so holds no
 * literal one.
 *
 * # What this does not reach
 *
 * A floor, not a proof of absence, and every miss below fails open:
 *
 * - A verb reaching an argv through a variable (`const verb = 'ls-files'`) or
 *   as a variadic call argument (`git(cwd, 'ls-files')`). Neither shape exists
 *   in this source, and catching them needs data flow, not a literal test.
 * - A shell command string (`execSync('git ls-files')`). None exists here; a
 *   string like that is a command line, not an argv element.
 * - TypeScript outside `.gaia/cli/src`, where nothing runs a git listing.
 *
 * One boundary fails closed: a listing verb in an array that is not an argv at
 * all, a plain word list, reads as an offense. Route it or reword it.
 *
 * `status --porcelain` is outside the verb set on purpose: `-z` alone suffices
 * for it, and the `git-z.ts` docblock states that half of the contract.
 *
 * Repair, when this goes red: build the argv with `gitZArgs(verb, args)` and
 * split the output with `splitZStream`.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the suite
 * skips there. Mirrors `command-reachability.test.ts`.
 */
import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';
import {collectTreeFiles, TS_SOURCE_EXTENSIONS} from './util/tree-walk.js';

const GUARD_TOKEN = 'git-z-chokepoint';

const MARKER_OPENER = new RegExp(
  String.raw`^//\s*gaia-lint-ignore\s+${GUARD_TOKEN}\b`,
  'u'
);

const MARKER_REASON = new RegExp(
  String.raw`^//\s*gaia-lint-ignore\s+${GUARD_TOKEN}:\s*\S`,
  'u'
);

// gaia-lint-ignore git-z-chokepoint: the verb set this guard matches, which
// is data about argv rather than an argv itself.
const LISTING_VERBS: ReadonlySet<string> = new Set([
  'diff',
  'diff-tree',
  'ls-files',
  'ls-tree',
]);

/** The helper's own specification, relative to `.gaia/cli/src`. */
const CHOKEPOINT_SPEC = 'util/git-z.test.ts';

type Findings = {
  malformed: number[];
  offenses: number[];
  stale: number[];
  verbs: {line: number; verb: null | string}[];
};

const isStringLiteral = (
  node: ts.Node
): node is ts.NoSubstitutionTemplateLiteral | ts.StringLiteral =>
  ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node);

const holdsStatements = (node: ts.Node): boolean =>
  ts.isBlock(node) ||
  ts.isSourceFile(node) ||
  ts.isModuleBlock(node) ||
  ts.isCaseClause(node) ||
  ts.isDefaultClause(node);

/**
 * The array element a literal stands as, reached through the wrappers that
 * leave its value the verb: parentheses, a type assertion, `as`, `satisfies`,
 * and either branch of a conditional. Without the climb, `['ls-files' as
 * const]` is a raw argv the direct-parent test never sees.
 */
const argvElementOf = (node: ts.Node): ts.Node => {
  let current = node;

  while (
    ts.isParenthesizedExpression(current.parent) ||
    ts.isAsExpression(current.parent) ||
    ts.isSatisfiesExpression(current.parent) ||
    ts.isTypeAssertionExpression(current.parent) ||
    (ts.isConditionalExpression(current.parent) &&
      current.parent.condition !== current)
  ) {
    current = current.parent;
  }

  return current;
};

/** The statement an expression sits in: the node whose parent lists it. */
const statementOf = (node: ts.Node): ts.Node => {
  let current = node;

  while (!holdsStatements(current.parent)) {
    current = current.parent;
  }

  return current;
};

/**
 * Reports, by 1-based line, every raw listing argv, every marker exempting
 * nothing, every marker missing its reason, and the verb each `gitZArgs`
 * call names (`null` when it names none as a literal).
 */
const findOffenses = (source: string): Findings => {
  const file = ts.createSourceFile(
    'module.ts',
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS
  );
  const lineOf = (position: number): number =>
    file.getLineAndCharacterOfPosition(position).line;
  const markerText = (range: ts.CommentRange): string =>
    source.slice(range.pos, range.end);
  const isMarker = (range: ts.CommentRange): boolean =>
    range.kind === ts.SyntaxKind.SingleLineCommentTrivia &&
    MARKER_OPENER.test(markerText(range));
  const hasReason = (range: ts.CommentRange): boolean =>
    MARKER_REASON.test(markerText(range));

  /**
   * The well-formed markers in the comment run directly above `statement`.
   * The run is the suffix of its leading comments with no blank line inside
   * it or between it and the statement, so a marker parked a paragraph above
   * attaches to nothing and is reported rather than honored.
   */
  const markersAbove = (statement: ts.Node): ts.CommentRange[] => {
    const leading =
      ts.getLeadingCommentRanges(source, statement.getFullStart()) ?? [];
    const run: ts.CommentRange[] = [];
    let expectedEndLine = lineOf(statement.getStart(file)) - 1;

    for (const range of leading.toReversed()) {
      if (lineOf(range.end) !== expectedEndLine) {
        break;
      }

      run.push(range);
      expectedEndLine = lineOf(range.pos) - 1;
    }

    return run.filter((range) => isMarker(range) && hasReason(range));
  };

  // Each offending statement's exempting markers, computed once and read again
  // below to tell a used marker from a stale one.
  const offendingStatements = new Map<ts.Node, ts.CommentRange[]>();
  const offenses: number[] = [];
  const verbs: Findings['verbs'] = [];
  const allMarkers = new Map<number, ts.CommentRange>();
  const scannedPositions = new Set<number>();

  // A node shares its start with its first child, so most positions are
  // reached many times over; the trivia there only needs reading once.
  const collectMarkers = (position: number): void => {
    if (scannedPositions.has(position)) {
      return;
    }

    scannedPositions.add(position);

    for (const range of [
      ...(ts.getLeadingCommentRanges(source, position) ?? []),
      ...(ts.getTrailingCommentRanges(source, position) ?? []),
    ]) {
      if (isMarker(range)) {
        allMarkers.set(range.pos, range);
      }
    }
  };

  const checkArgvElement = (node: ts.Node): void => {
    if (
      !isStringLiteral(node) ||
      !LISTING_VERBS.has(node.text) ||
      !ts.isArrayLiteralExpression(argvElementOf(node).parent)
    ) {
      return;
    }

    const statement = statementOf(node);
    const exempting =
      offendingStatements.get(statement) ?? markersAbove(statement);

    if (exempting.length === 0) {
      offenses.push(lineOf(node.getStart(file)) + 1);
    }

    offendingStatements.set(statement, exempting);
  };

  const recordServedVerb = (node: ts.Node): void => {
    if (
      !ts.isCallExpression(node) ||
      !ts.isIdentifier(node.expression) ||
      node.expression.text !== 'gitZArgs'
    ) {
      return;
    }

    const [first] = node.arguments;

    verbs.push({
      line: lineOf(node.getStart(file)) + 1,
      verb: first !== undefined && isStringLiteral(first) ? first.text : null,
    });
  };

  // Walks `getChildren` rather than `ts.forEachChild` because only the former
  // reaches tokens, and a marker above a closing `}` is leading trivia of that
  // token alone: missing it would leave a marker exempting nothing unreported.
  const visit = (node: ts.Node): void => {
    // A JSDoc node's children sit inside the comment's own text, where a
    // comment scan would read prose as trivia.
    if (
      node.kind >= ts.SyntaxKind.FirstJSDocNode &&
      node.kind <= ts.SyntaxKind.LastJSDocNode
    ) {
      return;
    }

    collectMarkers(node.pos);
    checkArgvElement(node);
    recordServedVerb(node);

    for (const child of node.getChildren(file)) {
      visit(child);
    }
  };

  visit(file);

  const used = new Set(
    [...offendingStatements.values()].flat().map((range) => range.pos)
  );
  const markers = [...allMarkers.values()];

  return {
    malformed: markers
      .filter((range) => !hasReason(range))
      .map((range) => lineOf(range.pos) + 1),
    offenses,
    stale: markers
      .filter((range) => hasReason(range) && !used.has(range.pos))
      .map((range) => lineOf(range.pos) + 1),
    verbs,
  };
};

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const sourcesPresent = existsSync(cliSrc);

let scanCache: undefined | {file: string; findings: Findings}[];

/** Every source file's findings, parsed once and shared by the tree tests. */
const scanTree = (): {file: string; findings: Findings}[] => {
  scanCache ??= collectTreeFiles(cliSrc, TS_SOURCE_EXTENSIONS).map(
    (relative) => ({
      file: relative,
      findings: findOffenses(readFileSync(path.join(cliSrc, relative), 'utf8')),
    })
  );

  return scanCache;
};

const lines = (source: readonly string[]): string => source.join('\n');

/** A canary test body, with `marker` standing directly above its call. */
const canary = (marker: readonly string[]): string =>
  lines([
    "test('the fixture path really is C-quoted', () => {",
    ...marker,
    "  const listed = execFileSync('git', ['ls-files'], {cwd});",
    '});',
  ]);

describe('git listing argv is built by gitZArgs', () => {
  // Maintainer-only guard: `sourcesPresent` is false on an adopter clone,
  // where `.gaia/cli/src` is release-excluded.
  test.skipIf(!sourcesPresent)(
    'no raw listing argv remains outside the chokepoint',
    () => {
      const scanned = scanTree();

      // A scan that reaches nothing reports nothing. `.gaia/cli/src` has held
      // hundreds of `.ts` files for the life of the CLI, so a count this low
      // means the walk or the extension filter broke. The walk reads the
      // filesystem rather than the index, so a new file is scanned before it
      // is staged, and this file's own presence is what proves it.
      expect(scanned.length).toBeGreaterThan(100);
      expect(scanned.map(({file}) => file)).toContain(
        'git-z-chokepoint.test.ts'
      );

      const report = scanned.flatMap(({file, findings}) => [
        ...(file === CHOKEPOINT_SPEC ? [] : findings.offenses).map(
          (line) => `.gaia/cli/src/${file}:${line} raw listing argv`
        ),
        ...findings.stale.map(
          (line) => `.gaia/cli/src/${file}:${line} marker exempts nothing`
        ),
        ...findings.malformed.map(
          (line) => `.gaia/cli/src/${file}:${line} marker gives no reason`
        ),
      ]);

      expect(report).toEqual([]);
    }
  );

  test.skipIf(!sourcesPresent)(
    'every verb gitZArgs serves is a verb this guard matches',
    () => {
      const calls = scanTree().flatMap(({file, findings}) =>
        findings.verbs.map((call) => ({...call, file}))
      );

      // Deriving the served set from nothing would pass vacuously.
      expect(calls.length).toBeGreaterThan(0);
      expect(
        calls
          .filter(({verb}) => verb === null || !LISTING_VERBS.has(verb))
          .map(
            ({file, line, verb}) =>
              `.gaia/cli/src/${file}:${line} ${verb ?? '<not a literal>'}`
          )
      ).toEqual([]);
    }
  );

  // No `skipIf`: these run against fixture strings, so they hold on any clone
  // and they are what establish that the detector above can report at all.
  // A corpus that happens to be clean would otherwise green a broken detector.
  test.each([...LISTING_VERBS])('reports a raw %s argv', (verb) => {
    const source = `runGit([${JSON.stringify(verb)}, '--', 'wiki/']);`;

    expect(findOffenses(source).offenses).toEqual([1]);
  });

  test('reports a raw argv behind leading options', () => {
    const source = lines([
      'const suites = execFileSync(',
      "  'git',",
      "  ['-C', REPO_ROOT, 'ls-files', '*.bats'],",
      "  {encoding: 'utf8'}",
      ');',
    ]);

    expect(findOffenses(source).offenses).toEqual([3]);
  });

  test('reports a verb the formatter put on a line of its own', () => {
    const source = lines([
      'const listed = sandboxGit(root, [',
      "  'diff-tree',",
      "  '--name-only',",
      ']);',
    ]);

    expect(findOffenses(source).offenses).toEqual([2]);
  });

  test('reports a verb spelled as a template literal', () => {
    expect(findOffenses('runGit([`ls-tree`]);').offenses).toEqual([1]);
  });

  test.each([
    ['parentheses', "runGit([('ls-files')]);"],
    ['an as-assertion', "runGit(['ls-files' as const]);"],
    ['satisfies', "runGit(['ls-files' satisfies string]);"],
    ['an angle-bracket assertion', "runGit([<string>'ls-files']);"],
    ['nested wrappers', "runGit([(('ls-files') as string)]);"],
  ])('reports a verb wrapped in %s', (_label, source) => {
    expect(findOffenses(source).offenses).toEqual([1]);
  });

  test('reports both branches of a conditional element', () => {
    const source = lines([
      'runGit([',
      "  cached ? 'diff' : 'diff-tree',",
      "  '--',",
      ']);',
    ]);

    expect(findOffenses(source).offenses).toEqual([2, 2]);
  });

  test.each([
    [
      "a verb compared in a conditional's test",
      "runGit([verb === 'ls-files' ? '-r' : '-l']);",
    ],
    [
      'a verb standing as the whole condition',
      "runGit([('ls-files') ? '-r' : '-l']);",
    ],
    [
      'a routed argv spread into a longer one',
      "run([...gitZArgs('ls-tree', ['-r', ref]), '--', 'wiki/']);",
    ],
  ])('passes %s', (_label, source) => {
    expect(findOffenses(source).offenses).toEqual([]);
  });

  test('passes a call routed through gitZArgs', () => {
    const source = lines([
      "runGit(gitZArgs('ls-files'));",
      "git(cwd, gitZArgs('diff', ['--numstat', range]));",
    ]);

    expect(findOffenses(source).offenses).toEqual([]);
  });

  test('ignores a verb outside the listing set', () => {
    const source = lines([
      "runGit(['rev-list', '--count', range]);",
      "runGit(['status', '--porcelain=v1', '-z']);",
    ]);

    expect(findOffenses(source).offenses).toEqual([]);
  });

  test('reports the verb gitZArgs is called with', () => {
    const source = lines([
      "gitZArgs('ls-files');",
      'gitZArgs(verb);',
      'gitZArgs();',
    ]);

    expect(findOffenses(source).verbs).toEqual([
      {line: 1, verb: 'ls-files'},
      {line: 2, verb: null},
      {line: 3, verb: null},
    ]);
  });

  describe('the exemption marker', () => {
    test('exempts the canary it sits above', () => {
      const findings = findOffenses(
        canary([
          `  // gaia-lint-ignore ${GUARD_TOKEN}: runs without -z on purpose.`,
        ])
      );

      expect(findings).toMatchObject({malformed: [], offenses: [], stale: []});
    });

    test('exempts a canary whose statement opens lines above the verb', () => {
      const source = lines([
        `// gaia-lint-ignore ${GUARD_TOKEN}: runs without -z on purpose.`,
        'const listed = sandboxGit(root, [',
        "  'diff-tree',",
        "  '--name-only',",
        ']);',
      ]);

      expect(findOffenses(source)).toMatchObject({offenses: [], stale: []});
    });

    test('honors a reason wrapped onto a continuation line', () => {
      const findings = findOffenses(
        canary([
          `  // gaia-lint-ignore ${GUARD_TOKEN}: runs without -z on purpose,`,
          '  // proving the fixture path is C-quoted.',
        ])
      );

      expect(findings).toMatchObject({malformed: [], offenses: [], stale: []});
    });

    test('a canary with its marker removed is reported', () => {
      expect(findOffenses(canary([])).offenses).toEqual([2]);
    });

    test('a marker giving no reason is reported and exempts nothing', () => {
      const findings = findOffenses(
        canary([`  // gaia-lint-ignore ${GUARD_TOKEN}:`])
      );

      expect(findings).toMatchObject({malformed: [2], offenses: [3]});
    });

    test('a marker separated by a blank line attaches to nothing', () => {
      const findings = findOffenses(
        canary([
          `  // gaia-lint-ignore ${GUARD_TOKEN}: runs without -z on purpose.`,
          '',
        ])
      );

      expect(findings).toMatchObject({offenses: [4], stale: [2]});
    });

    test('a marker above a statement with no raw argv is reported', () => {
      const source = lines([
        `// gaia-lint-ignore ${GUARD_TOKEN}: nothing below needs this.`,
        "runGit(gitZArgs('ls-files'));",
      ]);

      expect(findOffenses(source)).toMatchObject({offenses: [], stale: [1]});
    });

    test('a marker stranded above a closing brace is reported', () => {
      const source = lines([
        'const list = () => {',
        "  runGit(gitZArgs('ls-files'));",
        `  // gaia-lint-ignore ${GUARD_TOKEN}: below the last statement.`,
        '};',
      ]);

      expect(findOffenses(source)).toMatchObject({offenses: [], stale: [3]});
    });

    test("another guard's marker exempts nothing here", () => {
      const findings = findOffenses(
        canary(['  // gaia-lint-ignore lint-git-path-quoting: not this guard.'])
      );

      expect(findings).toMatchObject({offenses: [3], stale: []});
    });

    test('a marker in a block comment is not a marker', () => {
      const findings = findOffenses(
        canary([`  /* gaia-lint-ignore ${GUARD_TOKEN}: wrong comment kind. */`])
      );

      expect(findings.offenses).toEqual([3]);
    });
  });
});
