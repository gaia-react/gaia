/**
 * Maintainer guard: the recursive tree walk is declared once.
 *
 * `util/tree-walk.ts` holds the CLI's one `collectTreeFiles`, and every
 * whole-tree guard suite scans with it. Nothing noticed when the copies it
 * replaced arrived, and nothing would notice another: the next author who needs
 * a corpus reaches for the `recursive` option on `readdirSync` inline rather
 * than finding the module. `sonarjs/no-identical-functions` stayed silent
 * through every copy, and no threshold on it would have closed the class:
 * ESLint rules run per file, so that rule never compares functions across
 * files at all. A byte-identical copy planted in a second module therefore
 * keeps `pnpm lint:cli` green. The shell-side scanners reach no TypeScript.
 *
 * The failure another copy produces is invisible at the call site. A guard's
 * corpus is exactly the set it is trusted to have scanned, so a private walk
 * that stops normalizing separators, or that skips a directory the shared one
 * reports, still returns a plausible list and still greens. It just quietly
 * reaches less than the maintainer reading the pass believes, and an exclusion
 * or filter added to one walk reaches none of the others. The copies the
 * consolidation removed had already diverged that way: two shared a name, a
 * signature and a body but differed on separator normalization, another inlined
 * the walk against a module-level root, another carried a try/catch variant,
 * and another was a fresh recursion with its own `node_modules`/`dist`
 * exclusions, written by someone who had never seen the others.
 *
 * # What counts as an offense
 *
 * Either of two shapes, in any `.ts` file under `.gaia/cli/src` outside the
 * declaring module:
 *
 * - A call to `readdirSync` that passes the `recursive` option as a true
 *   literal. That is the shape the shared module's own docblock names as what
 *   the next author writes.
 * - A function that calls itself by name and lists a directory somewhere in its
 *   body: a function declaration, or an arrow or function expression bound to a
 *   `const`. The listing is any call named `readdirSync`, `readdir`,
 *   `opendirSync` or `opendir`, bare or through a receiver such as `fs.`. That
 *   is the shape a walk takes when its author reaches for no option at all.
 *
 * The second shape is read from the TypeScript AST rather than from text,
 * because recognizing it means knowing where a function body starts and ends,
 * and text cannot say that without becoming a tokenizer. A self-call and a
 * listing each match countless ordinary lines here; only their sharing one
 * function's body makes a walk. `typescript` resolves here as this workspace's
 * devDependency, which holds only while the guard stays test-resident.
 *
 * A walk that takes every file whatever its extension is not a reason to keep a
 * private copy: the shared walk takes `EVERY_EXTENSION` for exactly that case.
 *
 * # What this does not reach, and it is a floor rather than a clean bill of health
 *
 * `update/regen-regions.ts` falls outside both shapes on the merits rather than
 * by exemption. It walks iteratively, draining an explicit pending list with no
 * self-call, because `lstat` has to refuse to descend a symlinked subdirectory
 * that the `recursive` option would walk straight through.
 *
 * Further shapes are unreached, and a copy taking any of them slips:
 *
 * - Any other iterative walk, for the same reason `regen-regions.ts` is not
 *   read.
 * - Mutual recursion, where two functions each call the other, and recursion
 *   through `this.` or any property call rather than a bare name.
 * - A function reaching the tree through an alias or a wrapper that is not
 *   named as a listing, such as a local helper around `readdirSync`.
 * - The `recursive` option reached through a variable or a spread rather than
 *   written as a literal, or passed to anything but `readdirSync`.
 * - An option list long enough to push `recursive` past the bounded gap the
 *   text match allows after the call, and a read whose own argument list
 *   carries a `…Sync(` call ahead of the option, as in
 *   `readdirSync(realpathSync(root), …)`, which the neighbouring-call bound
 *   cannot tell from the nested `fs` call it exists to skip.
 *
 * The last two are the price of the text match's two bounds rather than
 * oversights, and neither is reachable by a call anyone writes here today: the
 * gap's ceiling sits far above the option list this API accepts, and no live
 * `readdirSync` call in this tree takes a `…Sync(` argument.
 *
 * Nothing is exempted by path except the declaring module itself, which is the
 * one place the declaration belongs. There is deliberately no allowlist beside
 * it, on the convention `command-reachability.test.ts` states and
 * `escape-regexp-uniqueness.test.ts` shipped: if something turns out to need to
 * be unlisted, design the allowlist then.
 *
 * Repair, when this goes red: delete the private walk and import
 * `collectTreeFiles` from `…/util/tree-walk.js`, with the extension set the
 * walk needs or `EVERY_EXTENSION`. If the new walk genuinely needs something
 * the shared one does not give, such as refusing to descend a symlink, say so
 * where it is declared and give it the iterative shape `regen-regions.ts`
 * takes.
 *
 * Because this file sits inside the surface it scans, its fixtures are
 * assembled at runtime rather than written as literals: a fixture spelled out
 * as a call would be reported as the very copy it plants. The self-recursive
 * fixtures need no such care: they sit inside string literals, which the AST
 * never reads as functions.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither these sources nor this test, and the corpus
 * scan skips there. Mirrors `escape-regexp-uniqueness.test.ts`.
 */
import ts from 'typescript';
import {describe, expect, test} from 'vitest';
import {CLI_SRC, testDeclaredOnce} from './util/uniqueness-guard-fixture.js';

/**
 * A directory read carrying the `recursive` option as a true literal.
 *
 * Matched over the whole source rather than line by line, so a call Prettier
 * has broken across several lines still reads as one.
 *
 * Two bounds keep the match on the call it started from. It admits no `;`, so
 * it cannot reach an option object declared in a later statement. And it
 * admits no further `…Sync(` call, so it cannot cross out of the listing into
 * a neighbouring `fs` call inside the same statement: `readdirSync(dir)` whose
 * loop or callback body calls `mkdirSync` or `rmSync` with a recursive option
 * is an ordinary shape here, and without this bound every one of them would be
 * reported as a private tree walk, under repair text that cannot fix it.
 */
const RECURSIVE_DIRECTORY_READ =
  /readdirSync\s*\((?:(?!Sync\s*\()[^;]){0,200}?recursive\s*:\s*true/u;

/** The `fs` calls that list a directory, matched by name whatever the receiver. */
const DIRECTORY_READS: ReadonlySet<string> = new Set([
  'opendir',
  'opendirSync',
  'readdir',
  'readdirSync',
]);

/**
 * The identifier a function calls itself by: a declaration's own name, or the
 * `const` an arrow or function expression is bound to.
 */
const selfName = (node: ts.Node): null | string => {
  if (ts.isFunctionDeclaration(node)) {
    return node.name?.text ?? null;
  }

  return (
      (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) &&
        ts.isVariableDeclaration(node.parent) &&
        ts.isIdentifier(node.parent.name)
    ) ?
      node.parent.name.text
    : null;
};

/**
 * The 1-based line of the first function that calls itself by name and lists a
 * directory somewhere in its body, or `null` when the source holds none.
 */
const findSelfRecursiveWalk = (source: string): null | number => {
  const file = ts.createSourceFile(
    'module.ts',
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS
  );

  /**
   * What the calls inside `node` are made through: `bare` holds identifier
   * callees alone, the only spelling a self-call is recognized by, and `named`
   * adds a property call's name, so `fs.readdirSync` reads as a listing.
   */
  const calleeNames = (
    node: ts.Node
  ): {bare: Set<string>; named: Set<string>} => {
    const bare = new Set<string>();
    const named = new Set<string>();

    const collect = (child: ts.Node): void => {
      if (ts.isCallExpression(child)) {
        if (ts.isIdentifier(child.expression)) {
          bare.add(child.expression.text);
          named.add(child.expression.text);
        } else if (ts.isPropertyAccessExpression(child.expression)) {
          named.add(child.expression.name.text);
        }
      }

      ts.forEachChild(child, collect);
    };

    ts.forEachChild(node, collect);

    return {bare, named};
  };

  // Depth-first in source order, so the first walk found is the first written,
  // and a helper wrapping a walk is visited before the walk inside it.
  const visit = (node: ts.Node): null | number => {
    const name = selfName(node);

    if (name !== null) {
      const {bare, named} = calleeNames(node);

      if (
        bare.has(name) &&
        [...DIRECTORY_READS].some((read) => named.has(read))
      ) {
        return file.getLineAndCharacterOfPosition(node.getStart(file)).line + 1;
      }
    }

    return ts.forEachChild(node, visit) ?? null;
  };

  return visit(file);
};

/**
 * Reports the 1-based line of the first recursive walk of either shape, or
 * `null` when the source contains none.
 */
const findRecursiveWalk = (source: string): null | number => {
  const match = RECURSIVE_DIRECTORY_READ.exec(source);
  const lines = [
    match === null ? null : source.slice(0, match.index).split('\n').length,
    findSelfRecursiveWalk(source),
  ].filter((line) => line !== null);

  return lines.length === 0 ? null : Math.min(...lines);
};

/** The one module allowed to walk a tree recursively. */
const DECLARING_MODULE = 'util/tree-walk.ts';

// Assembled rather than written out, for the reason the docblock gives: a
// literal fixture would be an offense in this very file. This is the only place
// the call's own text appears, and it carries no option of its own.
const READ_CALL_HEAD = 'readdirSync(root, {';
const RECURSIVE_OPTION = 'recursive: true';
const FILE_TYPES_OPTION = 'withFileTypes: true';

const asDirectoryRead = (options: readonly string[]): string =>
  [READ_CALL_HEAD, options.join(', '), '})'].join('');

// A plain single-directory listing, and a second `fs` call carrying a
// recursive option, for the fixtures that pin the neighbouring-call bound.
const LIST_CALL = 'readdirSync(dir)';

const nestedRecursiveCall = (helper: string): string =>
  [helper, '(path.join(dir, name), {', RECURSIVE_OPTION, '});'].join('');

describe('tree walk uniqueness', () => {
  testDeclaredOnce({
    corpusFloor: 50,
    corpusRoot: CLI_SRC,
    declaringModule: DECLARING_MODULE,
    findOffense: findRecursiveWalk,
    offense: 'walks a tree recursively',
  });

  // No `skipIf`: these run against assembled strings, so they hold on any clone
  // and they are what establish that the detector can report at all.
  test('reports an inline recursive read', () => {
    const source = [
      'const collect = (root: string): string[] =>',
      `  ${asDirectoryRead([RECURSIVE_OPTION])} as string[];`,
    ].join('\n');

    expect(findRecursiveWalk(source)).toBe(2);
  });

  // Prettier breaks a long option object across lines, and a line-by-line scan
  // would read the call and its option as unrelated.
  test('reports a read whose option object is broken across lines', () => {
    const source = [
      `const entries = ${READ_CALL_HEAD}`,
      `  ${FILE_TYPES_OPTION},`,
      `  ${RECURSIVE_OPTION},`,
      '});',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBe(1);
  });

  // The option is not always written first, and a match anchored to the first
  // key would miss every call that puts `withFileTypes` ahead of it.
  test('reports a read whose recursive option is not the first key', () => {
    const source = `const entries = ${asDirectoryRead([
      FILE_TYPES_OPTION,
      RECURSIVE_OPTION,
    ])};`;

    expect(findRecursiveWalk(source)).toBe(1);
  });

  // The boundary between a tree walk and an ordinary single-directory read.
  // Reporting this would red on every live caller that lists one directory.
  test('accepts a single-directory read', () => {
    const source = `const entries = ${asDirectoryRead([FILE_TYPES_OPTION])};`;

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // The shape no option names: the walk is the function calling itself.
  test('reports a hand-rolled walk that recurses per directory', () => {
    const source = [
      'const walk = (dir: string): string[] => {',
      `  const entries = ${asDirectoryRead([FILE_TYPES_OPTION])};`,
      '',
      '  return entries.flatMap((entry) =>',
      '    entry.isDirectory() ? walk(join(dir, entry.name)) : [entry.name]',
      '  );',
      '};',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBe(1);
  });

  // A declaration rather than a bound arrow, reading through a namespace import.
  test('reports a function declaration that recurses per directory', () => {
    const source = [
      'import fs from "node:fs";',
      '',
      'function walk(dir: string): string[] {',
      '  return fs.readdirSync(dir).flatMap((name) => walk(name));',
      '}',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBe(3);
  });

  // The live instances hide the walk inside a helper, so the report has to name
  // the inner function rather than the one a reader calls.
  test('reports a walk nested inside another function at its own line', () => {
    const source = [
      'const listTree = (root: string): string[] => {',
      '  const out: string[] = [];',
      '',
      '  const walk = (dir: string): void => {',
      '    for (const name of readdirSync(dir)) walk(name);',
      '  };',
      '',
      '  walk(root);',
      '',
      '  return out;',
      '};',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBe(4);
  });

  // Recursion is not the offense on its own: a tree of data is walked the same
  // way, and this corpus has many.
  test('accepts a recursive function that reads no directory', () => {
    const source = [
      'const depth = (node: Node): number =>',
      '  1 + Math.max(0, ...node.children.map((child) => depth(child)));',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // A call through a receiver reaches whatever that receiver holds, not the
  // enclosing function, so sharing its name is not recursion.
  test('accepts a same-named call made through a receiver', () => {
    const source = [
      'const walk = (dir: string): string[] =>',
      '  readdirSync(dir).flatMap((name) => visitor.walk(name));',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // Nor is reading a directory: the per-directory listing is the ordinary case.
  test('accepts a directory read in a function that never calls itself', () => {
    const source = [
      'const names = (dir: string): string[] =>',
      `  ${LIST_CALL}.filter((name) => name.endsWith(".md"));`,
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // What the statement bound buys: a match cannot reach out of the call's own
  // statement into an unrelated option object below it.
  test('accepts an option that sits past the end of the call statement', () => {
    const source = [
      `const entries = ${asDirectoryRead([FILE_TYPES_OPTION])};`,
      `const options = {${RECURSIVE_OPTION}};`,
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // What the neighbouring-call bound buys, in the shape with the largest live
  // collision surface: suites all over this tree list a directory and remove
  // its entries recursively in teardown, inside one statement. Without the
  // bound each one reports as a private tree walk, under repair text that
  // cannot fix it.
  test('accepts a listing whose loop body removes entries recursively', () => {
    const source = [
      `for (const name of ${LIST_CALL}) {`,
      `  ${nestedRecursiveCall('rmSync')}`,
      '}',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  // The same bound, reached through a callback rather than a loop body.
  test('accepts a listing whose callback creates directories recursively', () => {
    const source = [
      `const names = ${LIST_CALL}.map((name) => {`,
      `  ${nestedRecursiveCall('mkdirSync')}`,
      '  return name;',
      '});',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });

  test('accepts a file that reads no directory at all', () => {
    const source = [
      'import path from "node:path";',
      'export const x = 1;',
    ].join('\n');

    expect(findRecursiveWalk(source)).toBeNull();
  });
});
